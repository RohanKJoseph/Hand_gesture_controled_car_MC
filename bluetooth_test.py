import serial
import time

PORT = "COM7"       # CHANGE THIS
BAUDRATE = 9600

try:

    bluetooth = serial.Serial(
        port=PORT,
        baudrate=BAUDRATE,
        timeout=1
    )

    print("Bluetooth connected!")
    print("Sending test commands...")

    while True:

        command = input(
            "Enter command (F/B/L/R/S or Q): "
        ).upper()

        if command == "Q":
            break

        if command in ["F", "B", "L", "R", "S"]:

            bluetooth.write(
                command.encode("ascii")
            )

            print(
                f"Sent: {command}"
            )

        else:

            print("Invalid command.")


except serial.SerialException as e:

    print("Bluetooth connection failed.")
    print(e)


finally:

    if "bluetooth" in locals() and bluetooth.is_open:
        bluetooth.close()

    print("Bluetooth closed.")