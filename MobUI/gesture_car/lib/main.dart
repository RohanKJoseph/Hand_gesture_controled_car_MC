import 'package:flutter/material.dart';
import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';
import 'dart:async';
import 'dart:typed_data';
import 'gesture_camera_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const GestureCarApp());
}

class GestureCarApp extends StatelessWidget {
  const GestureCarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'GestureCar',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const BluetoothScreen(),
    );
  }
}

enum ControlMode { buttons, camera }

class BluetoothScreen extends StatefulWidget {
  const BluetoothScreen({super.key});

  @override
  State<BluetoothScreen> createState() => _BluetoothScreenState();
}

class _BluetoothScreenState extends State<BluetoothScreen> {
  final FlutterClassicBluetooth bluetooth = FlutterClassicBluetooth();

  List<BtcDevice> devices = [];
  BtcConnection? connection;
  Timer? heartbeatTimer;

  bool loading = false;
  bool connecting = false;
  ControlMode selectedMode = ControlMode.buttons;

  String status = 'Not connected';
  String message = 'Load your paired Bluetooth devices';

  bool get isConnected => connection != null && connection!.isConnected;

  Future<void> loadPairedDevices() async {
    setState(() {
      loading = true;
      message = 'Checking Bluetooth permissions...';
    });

    try {
      final supported = await bluetooth.isSupported();
      if (!supported) {
        throw Exception('Bluetooth Classic is not supported.');
      }

      final enabled = await bluetooth.isEnabled();
      if (!enabled) {
        throw Exception('Please turn on Bluetooth on your phone.');
      }

      final permissions = {BtcPermission.scan, BtcPermission.connect};

      final permissionStatus = await bluetooth.checkPermissions(
        permissions: permissions,
      );

      if (permissionStatus != BtcPermissionStatus.granted &&
          permissionStatus != BtcPermissionStatus.notRequired) {
        final result = await bluetooth.requestPermissions(
          permissions: permissions,
        );

        if (result != BtcPermissionStatus.granted &&
            result != BtcPermissionStatus.notRequired) {
          if (!mounted) return;

          setState(() {
            status = 'Bluetooth permission denied';
            message =
                'Please allow Nearby devices permission in Android settings.';
          });
          return;
        }
      }

      final pairedDevices = await bluetooth.getPairedDevices();

      if (!mounted) return;

      setState(() {
        devices = pairedDevices;
        message = devices.isEmpty
            ? 'No paired devices found. Pair HC-05 in Android Settings.'
            : 'Select your HC-05 to connect.';
      });
    } catch (e) {
      if (!mounted) return;

      setState(() {
        message = 'Error: $e';
      });
    } finally {
      if (mounted) {
        setState(() => loading = false);
      }
    }
  }

  Future<void> connectDevice(BtcDevice device) async {
    if (connecting) return;

    setState(() {
      connecting = true;
      status = 'Connecting...';
      message = 'Connecting to ${device.displayName}';
    });

    try {
      final newConnection = await bluetooth.connect(
        address: device.address,
        timeout: const Duration(seconds: 15),
      );

      if (!mounted) {
        await newConnection.close();
        newConnection.dispose();
        return;
      }

      setState(() {
        connection = newConnection;
        status = 'Connected';
        message = 'Bluetooth connection established!';
      });
    } catch (e, stackTrace) {
      debugPrint('BLUETOOTH CONNECTION ERROR: $e');
      debugPrintStack(stackTrace: stackTrace);

      if (!mounted) return;

      setState(() {
        status = 'Connection failed';
        message = e.toString();
        connection = null;
      });
    } finally {
      if (mounted) {
        setState(() => connecting = false);
      }
    }
  }

  Future<void> disconnectDevice() async {
    final current = connection;
    if (current == null) return;
    sendCommand('S');
    heartbeatTimer?.cancel();
    heartbeatTimer = null;

    setState(() {
      status = 'Disconnecting...';
    });

    try {
      await current.close();
      current.dispose();
    } catch (e) {
      debugPrint('Disconnect error: $e');
    }

    if (!mounted) return;

    setState(() {
      connection = null;
      status = 'Not connected';
      message = 'Bluetooth disconnected.';
      selectedMode = ControlMode.buttons;
    });
  }

  void sendCommand(String command) {
    if (connection == null) return;

    connection!.output.add(Uint8List.fromList(command.codeUnits));
  }

  void startDriving(String command) {
    heartbeatTimer?.cancel();

    sendCommand(command);

    heartbeatTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => sendCommand(command),
    );
  }

  void stopDriving() {
    heartbeatTimer?.cancel();
    heartbeatTimer = null;

    sendCommand('S');
  }

  Widget movementButton(String label, String command) {
    return GestureDetector(
      onTapDown: (_) => startDriving(command),
      onTapUp: (_) => stopDriving(),
      onTapCancel: stopDriving,
      child: Container(
        width: 90,
        height: 65,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.blue,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }

  Widget modeSelector() {
    return SegmentedButton<ControlMode>(
      segments: const [
        ButtonSegment(
          value: ControlMode.buttons,
          icon: Icon(Icons.gamepad),
          label: Text('Buttons'),
        ),
        ButtonSegment(
          value: ControlMode.camera,
          icon: Icon(Icons.camera_alt),
          label: Text('Hand Gesture'),
        ),
      ],
      selected: {selectedMode},
      onSelectionChanged: (selection) {
        stopDriving();
        setState(() {
          selectedMode = selection.first;
        });
      },
    );
  }

  Widget cameraModePanel() {
    return GestureCameraScreen(onCommand: startDriving, onStop: stopDriving);
  }

  Widget buttonControlPanel() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Press and hold to move',
          style: TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 24),
        movementButton('FORWARD', 'F'),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            movementButton('LEFT', 'L'),
            const SizedBox(width: 12),
            movementButton('STOP', 'S'),
            const SizedBox(width: 12),
            movementButton('RIGHT', 'R'),
          ],
        ),
        const SizedBox(height: 12),
        movementButton('BACKWARD', 'B'),
      ],
    );
  }

  @override
  void dispose() {
    heartbeatTimer?.cancel();
    heartbeatTimer = null;

    final current = connection;
    if (current != null) {
      current.close().whenComplete(() => current.dispose());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('GestureCar'), centerTitle: true),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: isConnected
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      child: ListTile(
                        leading: const Icon(
                          Icons.bluetooth_connected,
                          color: Colors.green,
                          size: 32,
                        ),
                        title: Text(status),
                        subtitle: Text(message),
                        trailing: const Icon(
                          Icons.check_circle,
                          color: Colors.green,
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    const Text(
                      'Choose control method',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.bold,
                      ),
                    ),

                    const SizedBox(height: 14),

                    modeSelector(),

                    const SizedBox(height: 25),

                    Expanded(
                      child: selectedMode == ControlMode.buttons
                          ? SingleChildScrollView(child: buttonControlPanel())
                          : cameraModePanel(),
                    ),

                    OutlinedButton.icon(
                      onPressed: disconnectDevice,
                      icon: const Icon(Icons.bluetooth_disabled),
                      label: const Text('Disconnect HC-05'),
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          children: [
                            const Icon(
                              Icons.bluetooth,
                              size: 55,
                              color: Colors.blueAccent,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              status,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 6),
                            Text(message, textAlign: TextAlign.center),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 24),

                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Paired devices',
                          style: TextStyle(
                            fontSize: 19,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          onPressed: loading ? null : loadPairedDevices,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    Expanded(
                      child: loading
                          ? const Center(child: CircularProgressIndicator())
                          : devices.isEmpty
                          ? const Center(
                              child: Text(
                                'No devices loaded.\n'
                                'Tap below to load paired devices.',
                                textAlign: TextAlign.center,
                              ),
                            )
                          : ListView.builder(
                              itemCount: devices.length,
                              itemBuilder: (context, index) {
                                final device = devices[index];

                                return Card(
                                  child: ListTile(
                                    leading: const Icon(
                                      Icons.bluetooth,
                                      color: Colors.lightBlueAccent,
                                    ),
                                    title: Text(device.displayName),
                                    subtitle: Text(device.address),
                                    trailing: ElevatedButton(
                                      onPressed: connecting
                                          ? null
                                          : () => connectDevice(device),
                                      child: const Text('Connect'),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),

                    const SizedBox(height: 12),

                    ElevatedButton.icon(
                      onPressed: loading || connecting
                          ? null
                          : loadPairedDevices,
                      icon: const Icon(Icons.devices),
                      label: const Text('Load paired devices'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
