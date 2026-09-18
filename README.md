# Vision Based Wireless Gesture Control for Autonomous Vehicles

Control a vehicle using hand gestures through a laptop webcam. Gestures are detected in real time using OpenCV and MediaPipe, and commands are sent wirelessly over Bluetooth to an STM32-powered vehicle.

---

## Team

| Name | Role |
|------|------|
| Rohan K Joseph | Team Lead |
| G S Balamurali | Member |
| Aebel Antosh | Member |
| Ewan John Dennis | Member |

---

## Gestures

| Gesture | Action |
|---------|--------|
| Index finger pointing up | Forward |
| Fist | Backward |
| Index finger pointing left | Left |
| Index finger pointing right | Right |
| Open palm | Stop |

---

## Project Structure

```
mcproject/
├── Vision_Controlled_Robot_MCProject/   # STM32 embedded C project
│   ├── Inc/
│   │   └── motor_control.h
│   └── Src/
│       ├── main.c
│       └── motor_control.c
├── models/
    ├── hand_landmarker.task             # MediaPipe Hand Landmark Model
├── gesture_controller.py                # OpenCV + MediaPipe gesture detection
├── bluetooth_test.py                    # Standalone Bluetooth test utility
└── requirements.txt
```

---

## Hardware

- STM32F103C8T6 (Blue Pill)
- TB6612FNG Dual DC Motor Driver
- HC-05 / HC-06 Bluetooth Module
- 2x DC Motors + Caster Wheel

---

## Setup

### Python (Gesture Detection)

```bash
python -m venv venv
venv\Scripts\activate
pip install -r requirements.txt
```

Download the MediaPipe hand landmark model and place it at:
```
models/hand_landmarker.task
```
Download link: https://ai.google.dev/edge/mediapipe/solutions/vision/hand_landmarker

Then run:
```bash
python gesture_controller.py
```

### Firmware (STM32)

Open the `Vision_Controlled_Robot_MCProject` folder in VS Code with the STM32 VS Code Extension installed.

```bash
cmake --preset Debug
cmake --build --preset Debug
```

Flash to the board using an ST-Link debugger.

---

## Dependencies

- Python 3.x
- OpenCV
- MediaPipe
- pyserial
- STM32CubeCLT
- STM32 VS Code Extension