#!/bin/bash
#
# Author   : Andrew (Drew) K2RHL
# Date     : 2 November 2026
# Updated  : 2 November 2026
# Version  : 2026.11.02-1300   (CalVer YYYY.MM.DD-HHMM, US Eastern)
# Purpose  : TEMPORARY test of a barcode scanner on EmComm Tools / Ubuntu
#           (e.g. Panasonic FZ-M1 barcode reader option). Changes NOTHING
#           permanently: no udev rules, no services, no config files.
#
# Changelog
#   2026.11.02-1300  Initial
#
# ---------------------------------------------------------------------------
# BACKGROUND
# ---------------------------------------------------------------------------
# Hardware barcode scanners decode the barcode THEMSELVES and send plain text.
# Linux needs no "interpreter" for them. They show up in one of two ways:
#   HID keyboard  - the scanner "types" the code into whatever window has focus.
#   USB serial    - the code arrives on a serial port (/dev/ttyACM* /dev/ttyUSB*).
#                   Many Honeywell engines can be triggered by software with
#                   SYN 'T' CR (0x16 0x54 0x0D) and stopped with SYN 'U' CR,
#                   if "serial trigger" mode is enabled in the scanner.
# Decoding with a CAMERA instead is done by zbar-tools (zbarcam / zbarimg).
#
# Panasonic notes: on Windows the FZ-M1 scanner is driven by Panasonic's
# "Barcode Reader" utility and the A1/A2 buttons. On Linux the side buttons
# may not trigger the engine; use the software trigger below. If nothing is
# detected, check BIOS (F2) for a barcode reader / xPAK setting = Enabled.
#
# Usage:
#   sudo ./et-barcode-test.sh            detect + test (HID and serial)
#   sudo ./et-barcode-test.sh --camera   decode with the camera (needs zbar-tools)
# ---------------------------------------------------------------------------

VERSION="2026.11.02-1300"
echo "et-barcode-test v${VERSION}  (temporary test - no permanent changes)"
[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo $0 $*"; exit 1; }

# USB vendor IDs of common scanner engine makers
SCANNER_VIDS="0c2e 0536 05e0 05f9 1eab 065a 2dd6 1d57"
declare -A VNAME=([0c2e]="Honeywell/Metrologic" [0536]="Hand Held Products (Honeywell)" [05e0]="Zebra/Symbol"
                  [05f9]="Datalogic" [1eab]="Newland" [065a]="Opticon" [2dd6]="Zebra (newer)" [1d57]="generic HID scanner")

prop() { udevadm info -q property -n "$1" 2>/dev/null | sed -n "s/^$2=//p" | head -1; }

camera_test() {
  if ! command -v zbarcam >/dev/null; then
    echo "zbar-tools is not installed. To install (temporary - remove later with 'sudo apt remove zbar-tools'):"
    echo "  sudo apt install zbar-tools"
    exit 1
  fi
  echo "Video devices:"; for v in /dev/video*; do [ -e "$v" ] && echo "  $v  $(cat "/sys/class/video4linux/${v#/dev/}/name" 2>/dev/null)"; done
  local cam="${CAM:-/dev/video0}"
  echo "Using $cam (set CAM=/dev/videoN to choose another, e.g. the rear camera)."
  echo "Hold a barcode in front of the camera. 30 s; decoded codes print below."
  timeout 30 zbarcam --raw --nodisplay "$cam" 2>/dev/null || timeout 30 zbarcam --raw "$cam"
  exit 0
}
[ "${1:-}" = "--camera" ] && camera_test

echo; echo "== 1. USB devices that look like scanners"
found=0
while read -r _ _ _ _ _ id rest; do
  vid=${id%%:*}
  if echo " $SCANNER_VIDS " | grep -q " $vid "; then echo "  $id  ${VNAME[$vid]:-?}  $rest"; found=1; fi
done < <(lsusb)
[ $found -eq 0 ] && echo "  none by vendor ID (internal scanners may use another chip - see sections 2 and 3)"

echo; echo "== 2. Keyboard-type input devices (a HID scanner appears here)"
grep -E '^(N: Name|H: Handlers)' /proc/bus/input/devices 2>/dev/null | paste - - | grep -w kbd \
  | sed -E 's/^N: Name="([^"]*)".*/  \1/'

echo; echo "== 3. Serial ports"
for t in /dev/ttyACM* /dev/ttyUSB*; do
  [ -e "$t" ] || continue
  echo "  $t  $(prop "$t" ID_VENDOR_ID):$(prop "$t" ID_MODEL_ID)  $(prop "$t" ID_MODEL)  if$(prop "$t" ID_USB_INTERFACE_NUM)  ET_DEVICE=$(prop "$t" ET_DEVICE)"
done

echo
echo "== 4. HID (keyboard) test"
echo "Press the scanner trigger now and scan a barcode (20 s). It should 'type' below:"
if read -r -t 20 code; then
  echo "  Received: '$code'"
  echo "  Hex     : $(printf '%s' "$code" | od -An -tx1 | tr -s ' ')"
else
  echo "  Nothing typed (not a HID scanner, not triggered, or disabled in BIOS)."
fi

echo
echo "== 5. Serial test (software trigger) - skips GPS, radio and modem ports"
for t in /dev/ttyACM* /dev/ttyUSB*; do
  [ -e "$t" ] || continue
  vid=$(prop "$t" ID_VENDOR_ID)
  # Never touch: GPS (u-blox, et-gps), Sierra modem, ETC radio/CAT/LoRa devices
  [ -n "$(prop "$t" ET_DEVICE)$(prop "$t" ET_LORA_DEVICE)" ] && { echo "  skip $t (ETC device $(prop "$t" ET_DEVICE)$(prop "$t" ET_LORA_DEVICE))"; continue; }
  case "$vid" in 1546|1199) echo "  skip $t (GPS/modem)"; continue;; esac
  # Writing to an unknown serial device is only done with explicit consent
  read -r -p "  Send scanner trigger (3 bytes) to $t ($(prop "$t" ID_MODEL))? [y/N] " yn
  [ "$yn" = "y" ] || [ "$yn" = "Y" ] || { echo "  skipped"; continue; }
  echo "  $t: sending Honeywell trigger, reading 8 s (also press the trigger button) ..."
  python3 - "$t" <<'PY'
import os, sys, time, select, termios
p = sys.argv[1]
try: fd = os.open(p, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
except OSError as e: print("    open failed:", e.strerror); sys.exit(0)
try:
    a = termios.tcgetattr(fd); a[0]=a[1]=a[3]=0; a[2]=termios.CS8|termios.CREAD|termios.CLOCAL
    a[4]=a[5]=termios.B115200; termios.tcsetattr(fd, termios.TCSANOW, a)
except termios.error: pass
os.write(fd, b"\x16T\r")
data, end = b"", time.time() + 8
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.5)
    if r:
        try: data += os.read(fd, 4096)
        except OSError: pass
os.write(fd, b"\x16U\r"); os.close(fd)
if data:
    print("    Received:", data.decode("ascii", "replace").strip())
    print("    Hex     :", data.hex(" "))
else:
    print("    nothing")
PY
done

echo
echo "Done. Nothing was changed. For camera decoding: sudo $0 --camera"
