import serial
import time

with serial.Serial(
    "COM4",
    9600,
    timeout=1,
    write_timeout=3,
    xonxoff=False,
    rtscts=False,
    dsrdtr=False
) as ser:
    time.sleep(1)

    ser.write(b"F")
    ser.flush()
    print("FORWARD sent")

    time.sleep(0.3)

    ser.write(b"S")
    ser.flush()
    print("STOP sent")

# import serial
# import time

# ser = serial.Serial("COM10", 9600, timeout=1)
# time.sleep(2)

# def drive(command, duration=0.5):
#     end = time.monotonic() + duration
#     while time.monotonic() < end:
#         ser.write(command.encode())
#         ser.flush()
#         time.sleep(0.1)

# try:
#     for command in ["F", "S", "B", "S", "L", "S", "R", "S"]:
#         print("Testing:", command)
#         drive(command, 0.5)
#         time.sleep(0.3)
# finally:
#     ser.write(b"S")
#     ser.close()