import cv2
import mediapipe as mp
import math
import time
from pathlib import Path
from collections import deque, Counter
from typing import Any
import serial

PORT = "COM7"       # change to your HC-05 port
BAUDRATE = 9600

try:
    bluetooth = serial.Serial(port=PORT, baudrate=BAUDRATE, timeout=1)
    bluetooth_connected = True
    print("Bluetooth connected.")
except serial.SerialException as e:
    bluetooth_connected = False
    print(f"Bluetooth not connected: {e}")

# ============================================================
# CONFIGURATION
# ============================================================

MODEL_PATH = Path(__file__).parent / "models" / "hand_landmarker.task"

CAMERA_ID = 0

# Number of previous predictions used for stabilization
STABILITY_FRAMES = 6

# Minimum number of matching predictions required
STABILITY_THRESHOLD = 4


# ============================================================
# CHECK MODEL
# ============================================================

if not MODEL_PATH.is_file():
    raise FileNotFoundError(
        f"\nMediaPipe model not found:\n{MODEL_PATH}\n"
    )


# ============================================================
# MEDIAPIPE SETUP
# ============================================================

BaseOptions = mp.tasks.BaseOptions
VisionRunningMode = mp.tasks.vision.RunningMode

HandLandmarker = mp.tasks.vision.HandLandmarker
HandLandmarkerOptions = mp.tasks.vision.HandLandmarkerOptions


options = HandLandmarkerOptions(
    base_options=BaseOptions(
        model_asset_path=str(MODEL_PATH)
    ),

    # IMPORTANT:
    # We are processing a continuous webcam stream.
    running_mode=VisionRunningMode.VIDEO,

    num_hands=1,

    min_hand_detection_confidence=0.7,
    min_hand_presence_confidence=0.7,
    min_tracking_confidence=0.7
)


hands = HandLandmarker.create_from_options(options)


# ============================================================
# CAMERA
# ============================================================

cap = cv2.VideoCapture(CAMERA_ID)

if not cap.isOpened():
    print("ERROR: Cannot open webcam")
    exit()


# Try to request 1280x720
cap.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)


# ============================================================
# MEDIAPIPE LANDMARK CONNECTIONS
# ============================================================

CONNECTIONS = [
    # Thumb
    (0, 1),
    (1, 2),
    (2, 3),
    (3, 4),

    # Index
    (0, 5),
    (5, 6),
    (6, 7),
    (7, 8),

    # Middle
    (0, 9),
    (9, 10),
    (10, 11),
    (11, 12),

    # Ring
    (0, 13),
    (13, 14),
    (14, 15),
    (15, 16),

    # Pinky
    (0, 17),
    (17, 18),
    (18, 19),
    (19, 20),

    # Palm connections
    (5, 9),
    (9, 13),
    (13, 17)
]


# ============================================================
# FINGER INFORMATION
# ============================================================

FINGER_TIPS = {
    4: "THUMB",
    8: "INDEX",
    12: "MIDDLE",
    16: "RING",
    20: "PINKY"
}


# ============================================================
# HELPER FUNCTIONS
# ============================================================

def distance(p1, p2):
    """
    Euclidean distance between two MediaPipe landmarks.
    """

    return math.sqrt(
        (p1.x - p2.x) ** 2 +
        (p1.y - p2.y) ** 2
    )


def calculate_angle(a: Any, b: Any, c: Any) -> float:
    """Calculate angle ABC in degrees."""

    ba_x = a.x - b.x
    ba_y = a.y - b.y

    bc_x = c.x - b.x
    bc_y = c.y - b.y

    dot = ba_x * bc_x + ba_y * bc_y

    mag_ba = math.sqrt(ba_x ** 2 + ba_y ** 2)
    mag_bc = math.sqrt(bc_x ** 2 + bc_y ** 2)

    if mag_ba == 0 or mag_bc == 0:
        return 0

    cosine = dot / (mag_ba * mag_bc)
    cosine = max(-1.0, min(1.0, cosine))

    return math.degrees(math.acos(cosine))


def finger_extended(landmarks: Any, mcp: int, pip: int, tip: int) -> bool:
    """Detect whether a finger is extended using its joint angle."""

    angle = calculate_angle(
        landmarks[mcp],
        landmarks[pip],
        landmarks[tip]
    )

    return angle > 150


def classify_gesture(landmarks: Any) -> tuple[str, str]:

    index_extended = finger_extended(landmarks, 5, 6, 8)
    middle_extended = finger_extended(landmarks, 9, 10, 12)
    ring_extended = finger_extended(landmarks, 13, 14, 16)
    pinky_extended = finger_extended(landmarks, 17, 18, 20)

    if (
        index_extended
        and middle_extended
        and ring_extended
        and pinky_extended
    ):
        return "STOP", "S"

    if (
        not index_extended
        and not middle_extended
        and not ring_extended
        and not pinky_extended
    ):
        return "BACKWARD", "B"

    if (
        index_extended
        and not middle_extended
        and not ring_extended
        and not pinky_extended
    ):
        mcp = landmarks[5]
        tip = landmarks[8]

        dx = tip.x - mcp.x
        dy = tip.y - mcp.y

        magnitude = math.sqrt(dx * dx + dy * dy)

        if magnitude < 0.05:
            return "UNKNOWN", "X"

        dx /= magnitude
        dy /= magnitude

        horizontal_strength = abs(dx)
        vertical_strength = abs(dy)

        if (
            dx > 0.55
            and horizontal_strength > vertical_strength * 1.05
        ):
            return "RIGHT", "R"

        if (
            dx < -0.55
            and horizontal_strength > vertical_strength * 1.05
        ):
            return "LEFT", "L"

        if (
            dy < -0.55
            and vertical_strength > horizontal_strength * 1.05
        ):
            return "FORWARD", "F"

    return "UNKNOWN", "X"


def calculate_steering(landmarks: Any) -> tuple[str, float, float]:
    """Calculate steering direction, intensity, and signed angle."""

    mcp = landmarks[5]
    tip = landmarks[8]

    dx = tip.x - mcp.x
    dy = tip.y - mcp.y

    angle = math.degrees(
        math.atan2(dx, -dy)
    )

    dead_zone = 10.0

    if abs(angle) < dead_zone:
        return "STRAIGHT", 0.0, angle

    max_angle = 55.0

    limited_angle = max(
        -max_angle,
        min(max_angle, angle)
    )

    turn_strength = (
        abs(limited_angle) - dead_zone
    ) / (
        max_angle - dead_zone
    )

    turn_strength = max(
        0.0,
        min(1.0, turn_strength)
    )

    turn_strength = turn_strength ** 0.8

    direction = "RIGHT" if angle > 0 else "LEFT"

    return direction, turn_strength, angle


# ============================================================
# DRAW GLOWING LINE
# ============================================================

def draw_glow_line(
    frame,
    pt1,
    pt2,
    color=(0, 255, 255),
    thickness=2
):

    """
    Creates a simple neon/glowing line effect.

    We draw:
        thick dark/bright layer
        ↓
        thinner bright layer
    """

    # Glow layer
    cv2.line(
        frame,
        pt1,
        pt2,
        color,
        thickness + 8,
        cv2.LINE_AA
    )

    # Main line
    cv2.line(
        frame,
        pt1,
        pt2,
        (255, 255, 255),
        thickness,
        cv2.LINE_AA
    )


# ============================================================
# DRAW HAND
# ============================================================

def draw_beautiful_hand(frame, landmarks, gesture):

    h, w, _ = frame.shape

    points = []

    # --------------------------------------------------------
    # Convert normalized MediaPipe coordinates to pixels
    # --------------------------------------------------------

    for landmark in landmarks:

        x = int(landmark.x * w)
        y = int(landmark.y * h)

        points.append((x, y))


    # --------------------------------------------------------
    # Draw index direction vector
    # --------------------------------------------------------

    index_mcp = points[5]
    index_tip = points[8]

    dx = index_tip[0] - index_mcp[0]
    dy = index_tip[1] - index_mcp[1]

    length = math.sqrt(
        dx * dx + dy * dy
    )

    if length > 0 and gesture != "STOP":

        scale = 1.5

        end_x = int(
            index_tip[0] + dx * scale
        )

        end_y = int(
            index_tip[1] + dy * scale
        )

        cv2.arrowedLine(
            frame,
            index_mcp,
            (end_x, end_y),
            (0, 255, 100),
            3,
            cv2.LINE_AA,
            tipLength=0.2
        )


    # --------------------------------------------------------
    # Hand bounding box
    # --------------------------------------------------------

    xs = [p[0] for p in points]
    ys = [p[1] for p in points]

    min_x = max(min(xs) - 25, 0)
    max_x = min(max(xs) + 25, w)

    min_y = max(min(ys) - 25, 0)
    max_y = min(max(ys) + 25, h)

    # Transparent overlay for box
    overlay = frame.copy()

    cv2.rectangle(
        overlay,
        (min_x, min_y),
        (max_x, max_y),
        (0, 255, 100),
        2
    )

    frame[:] = cv2.addWeighted(
        overlay,
        0.7,
        frame,
        0.3,
        0
    )


    # --------------------------------------------------------
    # Draw skeleton
    # --------------------------------------------------------

    for start, end in CONNECTIONS:

        draw_glow_line(
            frame,
            points[start],
            points[end],
            (0, 220, 255),
            2
        )


    # --------------------------------------------------------
    # Draw landmarks
    # --------------------------------------------------------

    for i, point in enumerate(points):

        # Fingertips get larger circles
        if i in FINGER_TIPS:

            cv2.circle(
                frame,
                point,
                10,
                (0, 255, 100),
                -1,
                cv2.LINE_AA
            )

            cv2.circle(
                frame,
                point,
                13,
                (255, 255, 255),
                2,
                cv2.LINE_AA
            )

        else:

            cv2.circle(
                frame,
                point,
                5,
                (0, 255, 255),
                -1,
                cv2.LINE_AA
            )


    # --------------------------------------------------------
    # Label fingertips
    # --------------------------------------------------------

    for landmark_id, name in FINGER_TIPS.items():

        x, y = points[landmark_id]

        # Offset label
        label_x = x + 15
        label_y = y - 10

        # Keep label inside screen
        label_x = min(label_x, w - 130)
        label_y = max(label_y, 25)

        # Label background
        cv2.rectangle(
            frame,
            (label_x, label_y - 22),
            (label_x + 105, label_y + 5),
            (10, 20, 25),
            -1
        )

        cv2.rectangle(
            frame,
            (label_x, label_y - 22),
            (label_x + 105, label_y + 5),
            (0, 255, 200),
            1
        )

        cv2.putText(
            frame,
            name,
            (label_x + 5, label_y - 3),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.42,
            (0, 255, 200),
            1,
            cv2.LINE_AA
        )


    # --------------------------------------------------------
    # Gesture near hand
    # --------------------------------------------------------

    gesture_x = min_x
    gesture_y = max(min_y - 15, 30)

    cv2.putText(
        frame,
        gesture,
        (gesture_x, gesture_y),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.8,
        (0, 255, 100),
        2,
        cv2.LINE_AA
    )


# ============================================================
# DRAW TOP STATUS PANEL
# ============================================================

def draw_status_panel(
    frame,
    gesture,
    command,
    fps,
    hand_detected
):

    h, w, _ = frame.shape

    # --------------------------------------------------------
    # Main panel
    # --------------------------------------------------------

    overlay = frame.copy()

    cv2.rectangle(
        overlay,
        (20, 20),
        (430, 155),
        (5, 15, 20),
        -1
    )

    frame[:] = cv2.addWeighted(
        overlay,
        0.82,
        frame,
        0.18,
        0
    )


    # Border
    cv2.rectangle(
        frame,
        (20, 20),
        (430, 155),
        (0, 255, 200),
        2
    )


    # --------------------------------------------------------
    # Title
    # --------------------------------------------------------

    cv2.putText(
        frame,
        "STM32 GESTURE CONTROL",
        (40, 52),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.75,
        (0, 220, 255),
        2,
        cv2.LINE_AA
    )


    # --------------------------------------------------------
    # Gesture
    # --------------------------------------------------------

    cv2.putText(
        frame,
        f"GESTURE : {gesture}",
        (40, 90),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.7,
        (255, 255, 255),
        2,
        cv2.LINE_AA
    )


    # --------------------------------------------------------
    # Command
    # --------------------------------------------------------

    cv2.putText(
        frame,
        f"COMMAND : {command}",
        (40, 122),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.65,
        (0, 255, 100),
        2,
        cv2.LINE_AA
    )


    # --------------------------------------------------------
    # Hand status
    # --------------------------------------------------------

    status = "HAND DETECTED" if hand_detected else "NO HAND"

    status_color = (
        (0, 255, 100)
        if hand_detected
        else
        (0, 80, 255)
    )

    cv2.putText(
        frame,
        status,
        (40, 148),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.45,
        status_color,
        1,
        cv2.LINE_AA
    )


    # --------------------------------------------------------
    # FPS
    # --------------------------------------------------------

    cv2.putText(
        frame,
        f"FPS {fps:.1f}",
        (w - 130, 35),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.6,
        (0, 255, 200),
        2,
        cv2.LINE_AA
    )


# ============================================================
# DRAW GESTURE GUIDE
# ============================================================

def draw_gesture_guide(frame):

    h, w, _ = frame.shape

    panel_x = w - 280
    panel_y = 20

    # Panel
    overlay = frame.copy()

    cv2.rectangle(
        overlay,
        (panel_x, panel_y),
        (w - 20, 350),
        (5, 15, 20),
        -1
    )

    frame[:] = cv2.addWeighted(
        overlay,
        0.82,
        frame,
        0.18,
        0
    )

    # Border
    cv2.rectangle(
        frame,
        (panel_x, panel_y),
        (w - 20, 350),
        (0, 180, 255),
        2
    )

    # Title
    cv2.putText(
        frame,
        "GESTURE GUIDE",
        (panel_x + 20, panel_y + 35),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.65,
        (0, 220, 255),
        2,
        cv2.LINE_AA
    )

    gestures = [
        ("INDEX UP", "F", "FORWARD"),
        ("FIST", "B", "BACKWARD"),
        ("POINT LEFT", "L", "LEFT"),
        ("POINT RIGHT", "R", "RIGHT"),
        ("OPEN PALM", "S", "STOP")
    ]

    y = panel_y + 70

    for name, command, action in gestures:

        cv2.putText(
            frame,
            f"{command}  {name}",
            (panel_x + 20, y),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.48,
            (255, 255, 255),
            1,
            cv2.LINE_AA
        )

        cv2.putText(
            frame,
            action,
            (panel_x + 145, y),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.42,
            (0, 255, 150),
            1,
            cv2.LINE_AA
        )

        y += 52


# ============================================================
# GESTURE STABILIZER
# ============================================================

gesture_history: deque[tuple[str, str]] = deque(
    maxlen=STABILITY_FRAMES
)


def stabilize_gesture(gesture: tuple[str, str]) -> tuple[str, str]:

    gesture_history.append(gesture)

    # Don't classify until buffer is sufficiently populated
    if len(gesture_history) < STABILITY_FRAMES:

        return "UNKNOWN", "X"


    counter: Counter[tuple[str, str]] = Counter(gesture_history)

    (stable_gesture, stable_command), count = counter.most_common(1)[0]

    if count >= STABILITY_THRESHOLD:

        return stable_gesture, stable_command

    return "UNKNOWN", "X"


# ============================================================
# MAIN LOOP
# ============================================================

previous_time = time.time()

stable_gesture = "NO HAND"
stable_command = "X"
last_sent_command = "X"

print()
print("==========================================")
print(" STM32 GESTURE CONTROLLER")
print("==========================================")
print()
print("Gestures:")
print("  INDEX UP      -> FORWARD")
print("  FIST          -> BACKWARD")
print("  POINT LEFT    -> LEFT")
print("  POINT RIGHT   -> RIGHT")
print("  OPEN PALM     -> STOP")
print()
print("Press Q to quit.")
print()


while True:

    success, frame = cap.read()

    if not success:

        print("ERROR: Cannot read webcam")
        break


    # --------------------------------------------------------
    # Mirror webcam
    # --------------------------------------------------------

    frame = cv2.flip(frame, 1)


    # --------------------------------------------------------
    # Convert OpenCV BGR -> RGB
    # --------------------------------------------------------

    rgb = cv2.cvtColor(
        frame,
        cv2.COLOR_BGR2RGB
    )


    # --------------------------------------------------------
    # Create MediaPipe image
    # --------------------------------------------------------

    image = mp.Image(
        image_format=mp.ImageFormat.SRGB,
        data=rgb
    )


    # --------------------------------------------------------
    # VIDEO MODE
    #
    # MediaPipe requires a timestamp for each frame.
    # --------------------------------------------------------

    timestamp_ms = int(
        time.time() * 1000
    )


    results = hands.detect_for_video(
        image,
        timestamp_ms
    )


    gesture = "NO HAND"
    command = "X"

    hand_detected = False


    # --------------------------------------------------------
    # HAND DETECTED
    # --------------------------------------------------------

    if results.hand_landmarks:

        hand_detected = True

        landmarks = results.hand_landmarks[0]


        # ----------------------------------------------------
        # Classify
        # ----------------------------------------------------

        raw_gesture, raw_command = classify_gesture(
            landmarks
        )


        # ----------------------------------------------------
        # Stabilize
        # ----------------------------------------------------

        stable_result = stabilize_gesture(
            (raw_gesture, raw_command)
        )

        stable_gesture, stable_command = stable_result

        # Terminal output test
        if stable_command != "X" and stable_command != last_sent_command:
            print(f"COMMAND: {stable_command}")
            if bluetooth_connected:
                bluetooth.write(stable_command.encode("ascii"))
            last_sent_command = stable_command

        if stable_command != "X":
            lock_text = f"LOCKED: {stable_gesture}"
        else:
            lock_text = "ANALYZING..."

        cv2.putText(
            frame,
            lock_text,
            (20, 220),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            (0, 255, 150),
            2,
            cv2.LINE_AA
        )


        # ----------------------------------------------------
        # Draw hand
        # ----------------------------------------------------

        draw_beautiful_hand(
            frame,
            landmarks,
            raw_gesture
        )


        # Show raw classification separately
        cv2.putText(
            frame,
            f"RAW: {raw_gesture}",
            (20, 190),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.5,
            (180, 180, 180),
            1,
            cv2.LINE_AA
        )


    else:

        # Clear history when hand disappears
        gesture_history.clear()

        stable_gesture = "NO HAND"
        stable_command = "X"
        last_sent_command = "X"
        if bluetooth_connected:
            bluetooth.write(b"S")

    # --------------------------------------------------------
    # FPS
    # --------------------------------------------------------

    current_time = time.time()

    fps = 1 / max(
        current_time - previous_time,
        0.001
    )

    previous_time = current_time


    # --------------------------------------------------------
    # UI
    # --------------------------------------------------------

    draw_status_panel(
        frame,
        stable_gesture,
        stable_command,
        fps,
        hand_detected
    )


    draw_gesture_guide(frame)


    # --------------------------------------------------------
    # Bottom information
    # --------------------------------------------------------

    h, w, _ = frame.shape

    cv2.putText(
        frame,
        "OpenCV  +  MediaPipe  +  STM32",
        (25, h - 25),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.55,
        (0, 220, 255),
        1,
        cv2.LINE_AA
    )


    cv2.putText(
        frame,
        "Q : EXIT",
        (w - 100, h - 25),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.45,
        (180, 180, 180),
        1,
        cv2.LINE_AA
    )


    # --------------------------------------------------------
    # Show
    # --------------------------------------------------------

    cv2.imshow(
        "STM32 Gesture Controller",
        frame
    )


    # --------------------------------------------------------
    # Quit
    # --------------------------------------------------------

    if cv2.waitKey(1) & 0xFF == ord("q"):

        break


# ============================================================
# CLEANUP
# ============================================================

cap.release()

cv2.destroyAllWindows()

hands.close()

if bluetooth_connected:
    bluetooth.close()

print("Controller stopped.")