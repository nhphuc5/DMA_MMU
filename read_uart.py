import serial
import sys

print("[1] Kiem tra xem ban da nap file bitstream tren Vivado chua.")
print("[2] Hay bam nut RESET (SW7) tren mach FPGA VC707 de xem ket qua in ra...\n")

try:
    ser = serial.Serial('COM5', 115200, timeout=0.1)
except Exception as e:
    print("[LOI] Khong the mo cong COM5! Kiem tra cap USB hoac xem co app nao khac dang dung khong.")
    sys.exit(1)

while True:
    data = ser.read(1024)
    if data:
        sys.stdout.write(data.decode('utf-8', 'ignore'))
        sys.stdout.flush()
