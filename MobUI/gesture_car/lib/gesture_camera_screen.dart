import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:hand_landmarker/hand_landmarker.dart';

class GestureCameraScreen extends StatefulWidget {
  final ValueChanged<String> onCommand;
  final VoidCallback onStop;

  const GestureCameraScreen({
    super.key,
    required this.onCommand,
    required this.onStop,
  });

  @override
  State<GestureCameraScreen> createState() => _GestureCameraScreenState();
}

class _GestureCameraScreenState extends State<GestureCameraScreen> {
  CameraController? cameraController;
  HandLandmarkerPlugin? handLandmarker;
  Timer? cameraSafetyTimer;

  bool cameraReady = false;
  bool processing = false;
  bool disposed = false;

  String detectedGesture = 'Show your hand';
  String currentCommand = 'S';
  String? candidateCommand;
  int stableFrames = 0;

  List<Landmark> currentLandmarks = [];
  DateTime lastFrameReceived = DateTime.now();
  DateTime lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);

  // A little dead-zone avoids changing direction when the index finger
  // is almost diagonal or held nearly still.
  // User-adjustable controls: higher sensitivity lowers the direction
  // dead-zone; more response frames make recognition steadier but slower.
  double gestureSensitivity = 0.55;
  double responseFrames = 4;

  double get directionDeadZone => 0.24 - (gestureSensitivity * 0.19);
  int get framesToConfirm => responseFrames.round();

  @override
  void initState() {
    super.initState();
    cameraSafetyTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => checkCameraSafety(),
    );
    initializeCamera();
  }

  Future<void> initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        throw Exception('No camera found');
      }

      final selectedCamera = cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        selectedCamera,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      cameraController = controller;

      // These settings are deliberately moderate to improve detection
      // reliability in ordinary indoor lighting.
      handLandmarker = HandLandmarkerPlugin.create(
        numHands: 1,
        minHandDetectionConfidence: 0.55,
        delegate: HandLandmarkerDelegate.gpu,
      );

      await controller.initialize();
      if (!mounted || disposed) return;

      setState(() {
        cameraReady = true;
        detectedGesture = 'Show one hand inside the frame';
      });

      await controller.startImageStream(processCameraFrame);
    } catch (e, stackTrace) {
      debugPrint('Camera initialization error: $e');
      debugPrintStack(stackTrace: stackTrace);
      if (!mounted || disposed) return;

      setState(() {
        cameraReady = false;
        detectedGesture = 'Camera error: $e';
      });
      stopRobot();
    }
  }

  void processCameraFrame(CameraImage image) {
    lastFrameReceived = DateTime.now();

    final controller = cameraController;
    final landmarker = handLandmarker;

    if (processing || !cameraReady || controller == null || landmarker == null) {
      return;
    }

    // The 2.x plugin API uses synchronous detect(). Throttle inference so
    // it does not monopolize the UI thread on every camera frame.
    final now = DateTime.now();
    if (now.difference(lastProcessed).inMilliseconds < 160) return;

    lastProcessed = now;
    processing = true;

    try {
      final hands = landmarker.detect(
        image,
        controller.description.sensorOrientation,
      );

      if (!mounted || disposed) return;

      if (hands.isEmpty || hands.first.landmarks.length < 21) {
        currentLandmarks = [];
        // No hand means stop immediately; don't wait for gesture smoothing.
        resetGesture('NO HAND', 'S', immediateStop: true);
      } else {
        final landmarks = hands.first.landmarks;
        currentLandmarks = landmarks;
        final command = classifyHand(landmarks);
        updateGesture(gestureName(command), command);
      }
    } catch (e) {
      debugPrint('Hand detection error: $e');
      currentLandmarks = [];
      resetGesture('DETECTION ERROR', 'S', immediateStop: true);
    } finally {
      processing = false;
    }
  }

  // Distance from wrist to each fingertip is compared with distance from
  // wrist to that finger's PIP joint. This is much less sensitive to hand
  // rotation than comparing only the y coordinates.
  double distance(Landmark a, Landmark b) {
    final dx = a.x - b.x;
    final dy = a.y - b.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  bool fingerIsExtended(
    List<Landmark> points, {
    required int tip,
    required int pip,
  }) {
    final wristToTip = distance(points[0], points[tip]);
    final wristToPip = distance(points[0], points[pip]);

    return wristToTip > wristToPip * 1.16;
  }

  // MediaPipe landmarks are expressed in the camera sensor's image
  // coordinates. Rotate them into the upright preview coordinates, then
  // mirror the front camera to match CameraPreview.
  Offset displayPoint(Landmark point) {
    var x = point.x;
    var y = point.y;

    final orientation =
        cameraController?.description.sensorOrientation ?? 0;

    switch (orientation) {
      case 90:
        final oldX = x;
        x = 1.0 - y;
        y = oldX;
        break;
      case 180:
        x = 1.0 - x;
        y = 1.0 - y;
        break;
      case 270:
        final oldX = x;
        x = y;
        y = 1.0 - oldX;
        break;
      default:
        break;
    }

    if (cameraController?.description.lensDirection ==
        CameraLensDirection.front) {
      x = 1.0 - x;
    }

    return Offset(x, y);
  }

  String classifyHand(List<Landmark> points) {
    if (points.length < 21) return 'S';

    final index = fingerIsExtended(points, tip: 8, pip: 6);
    final middle = fingerIsExtended(points, tip: 12, pip: 10);
    final ring = fingerIsExtended(points, tip: 16, pip: 14);
    final pinky = fingerIsExtended(points, tip: 20, pip: 18);

    // Open palm = STOP. STOP takes priority over every other gesture.
    if (index && middle && ring && pinky) return 'S';

    // Fist = BACKWARD.
    if (!index && !middle && !ring && !pinky) return 'B';

    // Index finger only = directional control.
    if (index && !middle && !ring && !pinky) {
      // Direction is based on the index finger itself, not the wrist.
      final indexTip = displayPoint(points[8]);
      final indexBase = displayPoint(points[5]);
      final dx = indexTip.dx - indexBase.dx;
      final dy = indexTip.dy - indexBase.dy;

      if (dy < -directionDeadZone && dy.abs() > dx.abs() * 1.15) {
        return 'F';
      }

      if (dx.abs() > directionDeadZone && dx.abs() > dy.abs() * 1.15) {
        return dx < 0 ? 'L' : 'R';
      }
    }

    // Ambiguous/transitioning hand pose must never cause movement.
    return 'S';
  }

  String gestureName(String command) {
    switch (command) {
      case 'F':
        return 'FORWARD';
      case 'B':
        return 'BACKWARD';
      case 'L':
        return 'LEFT';
      case 'R':
        return 'RIGHT';
      default:
        return 'STOP';
    }
  }

  void updateGesture(String name, String command) {
    if (candidateCommand == command) {
      stableFrames++;
    } else {
      candidateCommand = command;
      stableFrames = 1;
    }

    if (stableFrames >= framesToConfirm && currentCommand != command) {
      currentCommand = command;
      if (command == 'S') {
        widget.onStop();
      } else {
        widget.onCommand(command);
      }
    }

    if (mounted) {
      setState(() {
        detectedGesture = name;
      });
    }
  }

  void resetGesture(
    String name,
    String command, {
    bool immediateStop = false,
  }) {
    candidateCommand = command;
    stableFrames = 0;

    if (immediateStop || currentCommand != command) {
      currentCommand = command;
      widget.onStop();
    }

    if (mounted) {
      setState(() {
        detectedGesture = name;
      });
    }
  }

  void stopRobot() {
    candidateCommand = 'S';
    stableFrames = 0;
    currentCommand = 'S';
    widget.onStop();
  }

  void checkCameraSafety() {
    if (disposed || currentCommand == 'S') return;

    final elapsed =
        DateTime.now().difference(lastFrameReceived).inMilliseconds;

    if (elapsed > 700) {
      resetGesture('CAMERA LOST - STOP', 'S', immediateStop: true);
    }
  }

  @override
  void dispose() {
    disposed = true;
    cameraSafetyTimer?.cancel();
    stopRobot();

    final controller = cameraController;
    if (controller != null) {
      if (controller.value.isStreamingImages) {
        controller.stopImageStream();
      }
      controller.dispose();
    }

    handLandmarker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!cameraReady || cameraController == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(detectedGesture, textAlign: TextAlign.center),
          ],
        ),
      );
    }

    final controller = cameraController!;

    return Column(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(controller),

                // Minimal guide frame. The live hand skeleton and fingertip
                // markers are drawn over the camera preview.
                IgnorePointer(
                  child: CustomPaint(
                    painter: HandOverlayPainter(
                      landmarks: currentLandmarks,
                      sensorOrientation:
                          controller.description.sensorOrientation,
                      mirrorX: controller.description.lensDirection ==
                          CameraLensDirection.front,
                    ),
                  ),
                ),

                Positioned(
                  top: 12,
                  left: 12,
                  child: _statusPill(
                    currentLandmarks.isEmpty ? 'SEARCHING' : 'HAND TRACKED',
                    currentLandmarks.isEmpty
                        ? Colors.white70
                        : Colors.greenAccent,
                  ),
                ),
                Positioned(
                  top: 12,
                  right: 12,
                  child: _statusPill('LIVE', Colors.redAccent),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 14,
            ),
            child: Row(
              children: [
                Icon(
                  currentCommand == 'S'
                      ? Icons.pan_tool_alt
                      : Icons.directions_car,
                  color: currentCommand == 'S'
                      ? Colors.orangeAccent
                      : Colors.lightBlueAccent,
                  size: 30,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        detectedGesture,
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Command: $currentCommand',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
                if (currentCommand == 'S')
                  const Text(
                    'STOP',
                    style: TextStyle(
                      color: Colors.orangeAccent,
                      fontWeight: FontWeight.bold,
                    ),
                  )
                else
                  const Icon(
                    Icons.circle,
                    color: Colors.greenAccent,
                    size: 12,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Keep your hand inside the frame • Open palm = STOP',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(height: 8),
        _tuningPanel(),
      ],
    );
  }

  Widget _tuningPanel() {
    return Card(
      child: ExpansionTile(
        initiallyExpanded: false,
        leading: const Icon(Icons.tune),
        title: const Text(
          'Gesture tuning',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: const Text('Adjust detection sensitivity and response'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Gesture sensitivity'),
              Text('${(gestureSensitivity * 100).round()}%'),
            ],
          ),
          Slider(
            value: gestureSensitivity,
            min: 0,
            max: 1,
            divisions: 20,
            label: '${(gestureSensitivity * 100).round()}%',
            onChanged: (value) {
              setState(() => gestureSensitivity = value);
            },
          ),
          const Text(
            'Higher sensitivity detects smaller direction changes, '
            'but may react to shaky fingers.',
            style: TextStyle(fontSize: 12, color: Colors.white70),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Response stability'),
              Text('${responseFrames.round()} frames'),
            ],
          ),
          Slider(
            value: responseFrames,
            min: 2,
            max: 8,
            divisions: 6,
            label: '${responseFrames.round()} frames',
            onChanged: (value) {
              setState(() => responseFrames = value);
            },
          ),
          const Text(
            'Lower values react faster. Higher values require a steadier '
            'gesture and help prevent accidental movement.',
            style: TextStyle(fontSize: 12, color: Colors.white70),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                setState(() {
                  gestureSensitivity = 0.55;
                  responseFrames = 4;
                });
              },
              icon: const Icon(Icons.restart_alt),
              label: const Text('Reset tuning'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusPill(String label, Color color) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withValues(alpha: 0.7)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 10,
            fontWeight: FontWeight.bold,
            letterSpacing: 1,
          ),
        ),
      ),
    );
  }
}

class HandOverlayPainter extends CustomPainter {
  final List<Landmark> landmarks;
  final int sensorOrientation;
  final bool mirrorX;

  const HandOverlayPainter({
    required this.landmarks,
    required this.sensorOrientation,
    required this.mirrorX,
  });

  static const List<List<int>> connections = [
    [0, 1], [1, 2], [2, 3], [3, 4],
    [0, 5], [5, 6], [6, 7], [7, 8],
    [5, 9], [9, 10], [10, 11], [11, 12],
    [9, 13], [13, 14], [14, 15], [15, 16],
    [13, 17], [0, 17], [17, 18], [18, 19], [19, 20],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    // Draw a subtle fixed guide frame even before a hand is detected.
    final guideRect = Rect.fromLTWH(
      size.width * 0.12,
      size.height * 0.12,
      size.width * 0.76,
      size.height * 0.76,
    );

    final guidePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.48)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    canvas.drawRRect(
      RRect.fromRectAndRadius(guideRect, const Radius.circular(22)),
      guidePaint,
    );

    _drawCornerMarks(canvas, guideRect);

    if (landmarks.length < 21) return;

    Offset pointFor(Landmark point) {
      var x = point.x;
      var y = point.y;

      switch (sensorOrientation) {
        case 90:
          final oldX = x;
          x = 1.0 - y;
          y = oldX;
          break;
        case 180:
          x = 1.0 - x;
          y = 1.0 - y;
          break;
        case 270:
          final oldX = x;
          x = y;
          y = 1.0 - oldX;
          break;
        default:
          break;
      }

      if (mirrorX) {
        x = 1.0 - x;
      }

      return Offset(x * size.width, y * size.height);
    }

    final linePaint = Paint()
      ..color = Colors.lightBlueAccent
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final jointPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final tipPaint = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.fill;

    for (final connection in connections) {
      canvas.drawLine(
        pointFor(landmarks[connection[0]]),
        pointFor(landmarks[connection[1]]),
        linePaint,
      );
    }

    for (var i = 0; i < landmarks.length; i++) {
      final point = pointFor(landmarks[i]);
      canvas.drawCircle(point, i == 0 ? 4.5 : 3.2, jointPaint);

      if ([4, 8, 12, 16, 20].contains(i)) {
        canvas.drawCircle(point, 5.0, tipPaint);
      }
    }

    // Draw a dynamic, minimal rectangle around the detected hand.
    final xs = landmarks.map((point) => pointFor(point).dx).toList();
    final ys = landmarks.map((point) => pointFor(point).dy).toList();

    final left = xs.reduce((a, b) => a < b ? a : b)
        .clamp(0.0, size.width)
        .toDouble();
    final right = xs.reduce((a, b) => a > b ? a : b)
        .clamp(0.0, size.width)
        .toDouble();
    final top = ys.reduce((a, b) => a < b ? a : b)
        .clamp(0.0, size.height)
        .toDouble();
    final bottom = ys.reduce((a, b) => a > b ? a : b)
        .clamp(0.0, size.height)
        .toDouble();

    final handRect = Rect.fromLTRB(
      (left - 12).clamp(0.0, size.width).toDouble(),
      (top - 12).clamp(0.0, size.height).toDouble(),
      (right + 12).clamp(0.0, size.width).toDouble(),
      (bottom + 12).clamp(0.0, size.height).toDouble(),
    );

    final boxPaint = Paint()
      ..color = Colors.greenAccent.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;

    canvas.drawRRect(
      RRect.fromRectAndRadius(handRect, const Radius.circular(14)),
      boxPaint,
    );
  }

  void _drawCornerMarks(Canvas canvas, Rect rect) {
    final paint = Paint()
      ..color = Colors.lightBlueAccent
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    const length = 18.0;
    final corners = [
      [rect.topLeft, 1.0, 1.0],
      [rect.topRight, -1.0, 1.0],
      [rect.bottomLeft, 1.0, -1.0],
      [rect.bottomRight, -1.0, -1.0],
    ];

    for (final corner in corners) {
      final origin = corner[0] as Offset;
      final sx = corner[1] as double;
      final sy = corner[2] as double;

      canvas.drawLine(
        origin,
        Offset(origin.dx + length * sx, origin.dy),
        paint,
      );
      canvas.drawLine(
        origin,
        Offset(origin.dx, origin.dy + length * sy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant HandOverlayPainter oldDelegate) {
    return oldDelegate.landmarks != landmarks ||
        oldDelegate.sensorOrientation != sensorOrientation ||
        oldDelegate.mirrorX != mirrorX;
  }
}
