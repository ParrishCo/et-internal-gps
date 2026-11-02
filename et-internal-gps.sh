#!/bin/bash
#
# Author   : Andrew (Drew) K2RHL
# Date     : 2 November 2026
# Updated  : 2 November 2026
# Version  : 2026.11.02-1620   (CalVer YYYY.MM.DD-HHMM, US Eastern)
# Purpose  : Plug-and-play fallback GPS for EmComm Tools (ETC) R7.
#           If no ETC-native GPS (e.g. USB u-blox) is plugged in, find a GPS
#           built into the computer - usually the GNSS receiver inside a
#           Sierra Wireless LTE modem (Panasonic FZ-M1 / FZ-G1 / CF-20 ...) -
#           and feed it to ETC through the same /dev/et-gps + gpsd path ETC
#           already uses. ETC's own GPS devices ALWAYS win.
#
# Changelog
#   2026.11.02-1620  report privacy: also hide MEID / ESN / IMSI / ICCID (EM7455
#                    "ATI" prints MEID, which was not redacted before).
#   2026.11.02-1550  No-modem help: detect, install and report now print a
#                    numbered, step-by-step checklist when no Sierra WWAN/GPS
#                    modem is on USB (label check, lsusb/dmesg/rfkill, BIOS
#                    Wireless WAN, Kit Configuration ID for this model,
#                    card/antenna seating, full power-off, USB GPS fallback).
#                    Function: no_wwan_help.
#   2026.11.02-1540  report fixes found on the CF-20 + EM7455 test:
#                    - "add-on installed (v)" showed no version: the sed matched
#                      the last letter "v" on the line. Now reads the stamp
#                      "et-internal-gps vX" and WARNs if the installed copy is a
#                      different version from the script running the report.
#                    - ETC view (et-system-info) is now run as the desktop user,
#                      not root (root has no ~/.config/emcomm-tools/user.json ->
#                      "jq: error" in the grid line).
#                    - conky WARN now says how to clear it.
#   2026.11.02-1530  Comments + report hints only (no logic change): how to make a
#                    Panasonic BIOS see a WWAN/GPS card added to a unit that was
#                    built without one (Kit Configuration -> Wireless WAN ID), P15.
#   2026.11.02-1300  First distributable release (replaces et-sierra-gps.sh).
#                    Single file; installs to /opt/et-internal-gps; never edits
#                    ETC files; ETC-native GPS always wins (udev link_priority);
#                    automatic failover when a native GPS is unplugged; radio
#                    off by default; support report; side-by-side compare.
#
# ===========================================================================
#  QUICK START (for users)
# ===========================================================================
#   chmod +x et-internal-gps.sh
#   sudo ./et-internal-gps.sh detect      # read-only: what GPS hardware is here?
#   sudo ./et-internal-gps.sh install     # set it up (safe to re-run)
#   ./et-internal-gps.sh status           # is everything healthy?
#   ./et-internal-gps.sh test             # GPS data, fix, date, ETC view
#   sudo ./et-internal-gps.sh report      # ONE file to send back if anything is wrong
#   sudo ./et-internal-gps.sh uninstall   # remove everything this script added
#
#   Other commands: start, radio off|airplane|on|status, at 'AT...', compare [sec],
#                   serial-mode, normal-mode, version, help
#
# ===========================================================================
#  DESIGN RULES (why the code looks the way it does)
# ===========================================================================
#  1. ETC NATIVE ALWAYS WINS. ETC reads exactly one GPS: /dev/et-gps (gpsd runs
#     "-n -b /dev/et-gps", see /etc/default/gpsd). ETC's own udev rules (e.g.
#     92-et-u-blox.rules, IC-705/IC-7100 rules) create that symlink with udev's
#     default link priority 0. This add-on creates the SAME symlink for its
#     devices with NEGATIVE priority, so udev always points /dev/et-gps at the
#     native device when one is present, and falls back to ours when it is not:
#        native ETC device ........ priority   0   (ETC rules, untouched)
#        other USB GPS (u-blox 8+). priority  -5   (this add-on)
#        internal modem (Sierra) .. priority -10   (this add-on)
#        internal serial GPS (ttyS) priority -15   (this add-on)
#  2. NEVER MODIFY ETC FILES. Everything lives in our own files:
#        /opt/et-internal-gps/et-internal-gps.sh        (copy of this script)
#        /etc/et-internal-gps.conf                       (settings, commented)
#        /etc/udev/rules.d/91-et-internal-gps-usbmode.rules
#        /etc/udev/rules.d/94-et-internal-gps.rules
#        /etc/systemd/system/et-internal-gps-watchdog.{service,timer}
#        /var/log/et-internal-gps.log
#     Two SYSTEM (non-ETC) settings are changed and restored on uninstall:
#        /etc/usb_modeswitch.conf  DisableMBIMGlobal=1   (backup kept)
#        Sierra modem internal settings via AT commands (GPS enable, radio)
#  3. START gpsd THE ETC WAY. We call ETC's own wrapper
#     (/opt/emcomm-tools/sbin/wrapper-gpsd.sh start) exactly like ETC's u-blox
#     rule does - we never start gpsd with different options.
#  4. ONLY TOUCH OUR OWN DEVICES. Anything that writes to a GPS port first
#     checks the port belongs to this add-on (udev ET_DEVICE=ETIGPS-*).
#
# ===========================================================================
#  WHAT WE LEARNED ON A REAL FZ-M1 (EM7330, fw SWI9X15C_05.05.26) - each
#  problem below is now detected and fixed automatically
# ===========================================================================
#  P1  Sierra EM73xx modems expose TWO USB configurations. Linux picks the
#      data-only MBIM config (no serial ports, no GPS). We switch to the serial
#      config (DM/NMEA/AT/QMI). [usb_switch_serial, 91-...-usbmode.rules]
#  P2  Ubuntu's usb_modeswitch "MBIM check" forces the modem back to MBIM
#      ~1 s after every switch (dmesg: "'usb_modeswitch' sets config #2").
#      Fix: DisableMBIMGlobal=1 in /etc/usb_modeswitch.conf.
#  P3  A udev rule that re-selects the serial config on "add|change" is what
#      makes the switch stick (removing "change" made it worse). Kept.
#  P4  Repeated switching can hang the modem (writes time out, "error -110").
#      Software cannot fix that: a FULL power-off is required. report detects it.
#  P5  The Sierra GPS stream stops whenever its port is re-opened (gpsd start).
#      Fix: start gpsd FIRST, then send "$GPS_START" to the NMEA port.
#  P6  gpsd reported "Can't decode"/"no subscriber slots": ETC's et-api 1.3.0
#      leaks one gpsd connection per /api/geo/position call while there is no
#      fix (conky "Grid" line polls every 10 s). Watchdog restarts et-api when
#      gpsd clients pile up (ETAPI_GUARD). Reported upstream.
#  P7  A failed starter could leave /dev/et-gps as a REGULAR FILE; AppArmor then
#      blocks gpsd. We never write unless it is a character device; install and
#      status remove a stray file.
#  P8  Port numbers change after a modem reset (ttyUSB1 -> ttyUSB2). Ports are
#      found by USB interface number + role, never by ttyUSB number.
#  P9  ModemManager probes the modem ports. We tell it to ignore the GPS port
#      (and the whole modem when the radio is off - MM_IGNORE).
#  P10 Helper files placed inside /opt/emcomm-tools vanished once; we now keep
#      everything in /opt/et-internal-gps.
#  P11 ETC restarts gpsd when a native GPS is plugged in but not when it is
#      unplugged. We add a remove-rule that fails over to our device.
#  P12 SWI9X15C_05.xx firmware has the 2019 GPS week-rollover bug on some units
#      (wrong DATE, position fine). We check the GPS date and point to
#      Panasonic's fix (Windows tool) if it is wrong.
#  P13 GPS works with the cellular radio OFF (AT+CFUN=0) - lowest power, our default.
#  P14 Some USB ports on the FZ-M1 need a hub for USB GPS pucks (report shows
#      "no new USB device" when a plug-in is not seen).
#  P15 (BIOS - cannot be fixed from Linux) A Panasonic unit that was BUILT
#      WITHOUT cellular does not power the WWAN slot, even with a card fitted:
#      no "Wireless WAN" item in BIOS, nothing in lsusb/dmesg. Fix in BIOS Kit
#      Configuration - see "ENABLING A WWAN/GPS CARD IN A PANASONIC BIOS" below.
#      report flags this as "no Sierra modem on USB".
#  P16 (cosmetic) EM7455 on gpsd 3.22: cgps / gpsd SKY may list only the
#      GLONASS satellites. Raw NMEA shows GPS satellites in view ($GPGSV) and
#      $GNGNS mode "AAN" = fix uses GPS + GLONASS. Position is not affected.
#
# ===========================================================================
#  ENABLING A WWAN/GPS CARD IN A PANASONIC BIOS (P15)
# ===========================================================================
#  Tested 2 Nov 2026: CF-20 Mk2 CF-20G1165VM (built without WWAN, BIOS
#  V2.00L13) + Sierra EM7455 card moved from a CF-20G5142VM (built with LTE).
#
#  Symptoms : card fitted and antennas connected, but BIOS (F2) -> Advanced ->
#             Wireless Configuration has NO "Wireless WAN" item; lsusb shows no
#             1199:xxxx; dmesg shows nothing. The model number decides this at
#             the factory - Linux and this script cannot change it.
#  Fix      : 1. Power on, press F2 to enter BIOS Setup.
#             2. If a Supervisor password is set, enter it.
#             3. Main tab -> "Kit Configuration".
#             4. Enter the Panasonic service password: toughkit
#             5. Change "Wireless WAN ID" from FF (= none) to the value for
#                your model (values read from units that shipped WITH WWAN):
#                   CF-20 (Mk2) ......... 13   (EM7455 - tested, card then seen)
#                   FZ-G1 (Mk5) ......... 27   (EM7455)
#                   FZ-M1 (Mk2) ......... 15   (EM73xx)
#             6. F10 save, then SHUT DOWN fully (not reboot) and power on.
#             7. Check BIOS Advanced -> Wireless Configuration -> Wireless WAN =
#                Enabled, then in Linux: lsusb | grep -i 1199
#             8. sudo ./et-internal-gps.sh detect ; sudo ./et-internal-gps.sh install
#  Notes    : - FF = no WWAN. Other modules/models may need a DIFFERENT ID. The
#               safest source is the Kit Configuration of a unit of the same
#               model that shipped WITH that card - copy its Wireless WAN ID.
#             - Write down the original values before changing anything in Kit
#               Configuration; change ONLY Wireless WAN ID. The other kit fields
#               describe other factory options (wrong values can hide or
#               disable devices).
#             - Antennas: Main/AUX = cellular, GNSS lead (if any) = GPS. The GPS
#               needs its antenna lead connected to get a fix indoors/outdoors.
#
# ===========================================================================
#  TROUBLESHOOTING FOR MAINTAINERS
# ===========================================================================
#  - Everything we do is logged to the journal tag "et-internal-gps" and to
#    /var/log/et-internal-gps.log:  journalctl -t et-internal-gps -b
#  - "sudo ./et-internal-gps.sh report" collects system, USB, udev, gpsd,
#    chrony, ETC services, modem AT state and logs into one redacted file with
#    an automatic PASS/WARN/FAIL findings section.
#  - Adding support for another modem/chip: see detect_* functions and the
#    KNOWN_* tables below.
# ===========================================================================

set -u

VERSION="2026.11.02-1620"
APP="et-internal-gps"

# ---- Paths (ours) ----------------------------------------------------------
INSTALL_DIR="/opt/et-internal-gps"
INSTALLED_SELF="${INSTALL_DIR}/et-internal-gps.sh"
CONF="/etc/et-internal-gps.conf"
LOGFILE="/var/log/et-internal-gps.log"
RULE_USBMODE="/etc/udev/rules.d/91-et-internal-gps-usbmode.rules"
RULE_GPS="/etc/udev/rules.d/94-et-internal-gps.rules"
WD_SVC="/etc/systemd/system/et-internal-gps-watchdog.service"
WD_TMR="/etc/systemd/system/et-internal-gps-watchdog.timer"
RUN_DIR="/run/et-internal-gps"
UMS_CONF="/etc/usb_modeswitch.conf"
UMS_BACKUP="/etc/usb_modeswitch.conf.et-internal-gps.orig"

# ---- Paths (ETC - read/called only, never modified) ------------------------
ET_HOME="/opt/emcomm-tools"
ET_WRAPPER="${ET_HOME}/sbin/wrapper-gpsd.sh"
ET_SYSINFO="${ET_HOME}/bin/et-system-info"
ET_GPSD_DEFAULT="/etc/default/gpsd"
ET_UBLOX_RULE="/etc/udev/rules.d/92-et-u-blox.rules"

# ---- Paths from the earlier prototype (et-sierra-gps.sh) - removed on install
OLD_FILES=(
  /etc/udev/rules.d/93-et-sierra-gps.rules
  /etc/udev/rules.d/91-et-sierra-serial-mode.rules
  /opt/emcomm-tools/sbin/et-sierra-gps-start.sh
  /opt/emcomm-tools/sbin/et-sierra-gps-watchdog.sh
  /opt/emcomm-tools/sbin/et-sierra-serial-mode.sh
  /etc/systemd/system/et-sierra-gps-watchdog.service
  /etc/systemd/system/et-sierra-gps-watchdog.timer
)

# ---- Hardware knowledge ----------------------------------------------------
SIERRA_VID="1199"             # Sierra Wireless
UBLOX_VID="1546"              # u-blox (makes only GNSS chips)
NATIVE_UBLOX_PIDS="01a7 01a8" # handled by ETC's 92-et-u-blox.rules - never claim
# Sierra qcserial interface layout (Linux drivers/usb/serial/qcserial.c,
# QCSERIAL_SWI): if00 = DM (diagnostics), if02 = NMEA (GPS), if03 = AT.
# Used as first guess only; ports are verified by probing.
SIERRA_NMEA_IF_GUESS="02"
SIERRA_AT_IF_GUESS="03"

# ---- Settings (defaults; /etc/et-internal-gps.conf overrides) --------------
RADIO_MODE="off"          # off=AT+CFUN=0 (lowest power) | airplane=CFUN=4 | on=CFUN=1 | leave
MM_IGNORE="1"             # 1 = ModemManager ignores the modem (no LTE data)
WATCHDOG="1"              # 1 = check every 2 min that GPS data flows
ETAPI_GUARD="1"           # 1 = restart ETC et-api if gpsd clients pile up (P6)
ETAPI_MAX_CLIENTS="20"
SIERRA_SERIAL_CFG=""      # filled by install (USB configuration number)
SIERRA_NMEA_IF=""         # filled by install (USB interface number, e.g. 02)
SIERRA_AT_IF=""           # filled by install
SERIAL_GPS_TTY=""         # filled by install if an internal ttyS GPS is found
SERIAL_GPS_BAUD=""
# shellcheck disable=SC1090
[ -f "$CONF" ] && . "$CONF"

# ===========================================================================
#  Small helpers
# ===========================================================================
log() {   # log to screen, journal and our log file
  echo "$*"
  logger -t "$APP" -- "$*" 2>/dev/null
  [ -w "$(dirname "$LOGFILE")" ] && echo "$(date -Is) $*" >> "$LOGFILE" 2>/dev/null
}
die()       { log "ERROR: $*"; exit 1; }
need_root() { [ "$(id -u)" -eq 0 ] || { echo "Please run with sudo:  sudo $0 $*"; exit 1; }; }
have()      { command -v "$1" >/dev/null 2>&1; }
hr()        { printf '%s\n' "------------------------------------------------------------"; }

# udev property of a tty (e.g. prop /dev/ttyUSB1 ID_VENDOR_ID)
prop() { udevadm info -q property -n "$1" 2>/dev/null | sed -n "s/^$2=//p" | head -1; }

# Is this tty one of OUR devices? (set by our udev rule)
is_ours() { case "$(prop "$1" ET_DEVICE)" in ETIGPS-*) return 0;; esac; return 1; }

# Where does /dev/et-gps point right now (empty if missing/not a link)
etgps_target() { [ -L /dev/et-gps ] && readlink -f /dev/et-gps; }

# First USB device dir (sysfs) for a vendor ID
usbdev_for_vid() {
  local d
  for d in /sys/bus/usb/devices/*; do
    [ "$(cat "$d/idVendor" 2>/dev/null)" = "$1" ] && { echo "$d"; return 0; }
  done
  return 1
}

# tty for vendor + USB interface number
tty_for() {
  local vid="$1" ifn="$2" t
  for t in /dev/ttyUSB* /dev/ttyACM*; do
    [ -e "$t" ] || continue
    [ "$(prop "$t" ID_VENDOR_ID)" = "$vid" ] || continue
    [ -z "$ifn" ] && { echo "$t"; return 0; }
    [ "$(prop "$t" ID_USB_INTERFACE_NUM)" = "$ifn" ] && { echo "$t"; return 0; }
  done
  return 1
}

# USB configuration number whose interfaces have class $2 (255 = vendor/serial, 2 = MBIM/CDC)
usb_cfg_with_class() {
  lsusb -v -d "$1": 2>/dev/null | awk -v cls="$2" '
    /bConfigurationValue/ {c=$2}
    /bInterfaceClass/ && $2==cls && c!="" {print c; exit}'
}

gpsd_clients() { ss -Htn state established '( dport = :2947 )' 2>/dev/null | wc -l; }

# Count valid NMEA sentences on a port (checksums verified) in N seconds.
#   nmea_probe <tty> <seconds> <send_gps_start 0|1> [baud]
# Read-only unless send_gps_start=1 (Sierra). Prints "<count> <talkers>".
nmea_probe() {
  python3 - "$1" "$2" "$3" "${4:-9600}" <<'PY'
import os, sys, time, select, termios
port, secs, start, baud = sys.argv[1], float(sys.argv[2]), sys.argv[3] == "1", sys.argv[4]
B = {"4800": termios.B4800, "9600": termios.B9600, "38400": termios.B38400, "115200": termios.B115200}
try:
    fd = os.open(port, (os.O_RDWR if start else os.O_RDONLY) | os.O_NOCTTY | os.O_NONBLOCK)
except OSError as e:
    print("0 open-failed:%s" % e.strerror); sys.exit(0)
try:
    a = termios.tcgetattr(fd)
    a[0] = 0; a[1] = 0; a[3] = 0
    a[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    a[4] = a[5] = B.get(baud, termios.B9600)
    termios.tcsetattr(fd, termios.TCSANOW, a)
except termios.error:
    pass
if start:
    try: os.write(fd, b"$GPS_START\r\n")
    except OSError: pass
buf, n, talk, end = b"", 0, set(), time.time() + secs
while time.time() < end:
    r, _, _ = select.select([fd], [], [], 0.5)
    if not r: continue
    try: buf += os.read(fd, 4096)
    except (BlockingIOError, OSError): continue
    while b"\n" in buf:
        line, buf = buf.split(b"\n", 1)
        s = line.decode("ascii", "replace").strip()
        if not s.startswith("$") or "*" not in s: continue
        body, cs = s[1:].split("*", 1)
        c = 0
        for ch in body: c ^= ord(ch)
        try:
            if c == int(cs[:2], 16):
                n += 1; talk.add(body[:5])
        except ValueError: pass
os.close(fd)
print(n, ",".join(sorted(talk)) or "-")
PY
}

# Send one AT command to a Sierra AT port, print the reply (CR stripped)
at_cmd() {
  local port="$1" cmd="$2"
  [ -c "$port" ] || return 1
  stty -F "$port" 115200 raw -echo 2>/dev/null
  exec 3<>"$port" || return 1
  printf '%s\r' "$cmd" >&3
  timeout 2 cat <&3 | tr -d '\r'
  exec 3>&-
}

sierra_at_port()   { tty_for "$SIERRA_VID" "${SIERRA_AT_IF:-$SIERRA_AT_IF_GUESS}"; }
sierra_nmea_port() { tty_for "$SIERRA_VID" "${SIERRA_NMEA_IF:-$SIERRA_NMEA_IF_GUESS}"; }

# Start gpsd exactly the way ETC does (falls back to systemctl if ETC wrapper missing)
start_gpsd_etc_way() {
  if [ -x "$ET_WRAPPER" ]; then "$ET_WRAPPER" start; else systemctl restart gpsd; fi
}

# ===========================================================================
#  Preflight: is this an ETC system we can safely add to?
# ===========================================================================
preflight() {
  local fail=0 c
  hr; echo "Preflight checks"; hr
  for c in lsusb udevadm gpspipe systemctl ss python3 stty timeout logger; do
    if have "$c"; then echo "PASS  command '$c'"; else echo "FAIL  command '$c' missing"; fail=1; fi
  done
  [ $fail -eq 1 ] && echo "      Install with: sudo apt install usbutils gpsd-clients python3 iproute2"
  if [ -d "$ET_HOME" ] && [ -x "$ET_WRAPPER" ]; then
    echo "PASS  EmComm Tools found ($( [ -x "$ET_SYSINFO" ] && "$ET_SYSINFO" release 2>/dev/null || echo 'release unknown'))"
  else
    echo "FAIL  EmComm Tools not found (need $ET_WRAPPER). This add-on extends ETC R6/R7+."; fail=1
  fi
  if grep -qE '^DEVICES="?/dev/et-gps"?' "$ET_GPSD_DEFAULT" 2>/dev/null; then
    echo "PASS  ETC gpsd reads /dev/et-gps ($ET_GPSD_DEFAULT)"
  else
    echo "WARN  $ET_GPSD_DEFAULT does not read /dev/et-gps - ETC GPS layout changed? Proceeding cautiously."
  fi
  [ -f "$ET_UBLOX_RULE" ] && echo "PASS  ETC native u-blox rule present (native GPS will win)" \
                          || echo "INFO  ETC native u-blox rule not found"
  grep -qi ubuntu /etc/os-release 2>/dev/null && echo "PASS  Ubuntu ($(. /etc/os-release; echo "$VERSION_ID"))" \
                                                || echo "WARN  not Ubuntu - untested"
  # P7: stray regular file at /dev/et-gps
  if [ -e /dev/et-gps ] && [ ! -L /dev/et-gps ]; then
    echo "FIX   /dev/et-gps is a regular file (AppArmor blocks gpsd) - removing"; rm -f /dev/et-gps
  fi
  return $fail
}

# ===========================================================================
#  Detection (read-only)
# ===========================================================================
# Prints one line per GPS source:  KIND|TTY|DETAIL
#   NATIVE  - device ETC itself handles (u-blox 01a7/01a8 or anything already
#             owning /dev/et-gps through an ETC rule)
#   USBGPS  - other USB GPS this add-on can claim (non-native u-blox)
#   SIERRA  - Sierra modem (may need serial-mode first: TTY "-")
#   SERIAL  - internal legacy serial GPS (ttyS*)
detect_sources() {
  local t v p own
  own=$(etgps_target)
  # Native: whatever currently owns /dev/et-gps and is not ours
  if [ -n "$own" ] && ! is_ours "$own"; then
    echo "NATIVE|$own|$(prop "$own" ET_DEVICE) $(prop "$own" ID_MODEL)"
  fi
  # USB GPS (u-blox family)
  for t in /dev/ttyACM* /dev/ttyUSB*; do
    [ -e "$t" ] || continue
    v=$(prop "$t" ID_VENDOR_ID); p=$(prop "$t" ID_MODEL_ID)
    [ "$v" = "$UBLOX_VID" ] || continue
    if echo " $NATIVE_UBLOX_PIDS " | grep -q " $p "; then
      [ "$t" = "$own" ] || echo "NATIVE|$t|u-blox $p (ETC rule)"
    else
      echo "USBGPS|$t|u-blox $p $(prop "$t" ID_MODEL)"
    fi
  done
  # Sierra modem
  local sdev; if sdev=$(usbdev_for_vid "$SIERRA_VID"); then
    echo "SIERRA|$(sierra_nmea_port || echo -)|$(cat "$sdev/product" 2>/dev/null) pid=$(cat "$sdev/idProduct") cfg='$(cat "$sdev/bConfigurationValue" 2>/dev/null)'"
  fi
  # Internal serial GPS (older Toughbooks wire GPS to a COM port) - probe read-only
  [ "${1:-}" = "--probe-serial" ] && for t in /dev/ttyS0 /dev/ttyS1 /dev/ttyS2 /dev/ttyS3 /dev/ttyS4; do
    [ -c "$t" ] || continue
    for b in 9600 4800; do
      local r; r=$(nmea_probe "$t" 3 0 "$b")
      [ "${r%% *}" -gt 2 ] 2>/dev/null && { echo "SERIAL|$t|baud=$b talkers=${r#* }"; break; }
    done
  done
}

# ---------------------------------------------------------------------------
# no_wwan_help - printed by detect, install and report when NO Sierra modem is
# on USB. Written for non-technical users: numbered steps, in the order that
# finds the cause fastest. The Kit Configuration value is suggested from the
# model name in the BIOS (DMI), e.g. "FZM1-2", "CF20-2", "FZ-G1...".
# Keep this list in sync with P4 and P15 in the header.
# ---------------------------------------------------------------------------
no_wwan_help() {
  local model wid
  model=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
  case "$(echo "$model" | tr -d ' -' | tr '[:lower:]' '[:upper:]')" in
    *CF20*) wid="13 (CF-20)";;
    *FZG1*) wid="27 (FZ-G1)";;
    *FZM1*) wid="15 (FZ-M1)";;
    *)      wid="see table below";;
  esac
  cat <<EOF

  NO INTERNAL LTE/GPS MODEM FOUND  (computer model: ${model:-unknown})
  ----------------------------------------------------------------------
  The built-in GPS on these Toughbooks lives inside the Sierra Wireless
  LTE ("WWAN") card. Linux does not see one. Check in this order:

  1. Does this unit HAVE a WWAN card?
     - Label (back / under the battery): an IMEI number, or a second
       FCC ID containing "WW", means it shipped with one.
     - Windows: Device Manager -> Ports shows "Sierra Wireless ... NMEA Port".
     No WWAN card? Use a USB GPS (e.g. u-blox VK-162) - ETC supports it
     natively. Nothing else to do; this add-on stays out of the way.

  2. Confirm what Linux sees (copy/paste):
       lsusb | grep -i 1199            (Sierra = 1199:xxxx; empty = not seen)
       sudo dmesg | grep -iE 'sierra|qcserial|1199'
       rfkill list                     (look for a WWAN line, "blocked: yes")

  3. BIOS: restart, press F2 (enter the Supervisor password if one is set).
     Advanced -> Wireless Configuration -> "Wireless WAN" = Enabled.
     F10 to save. Then SHUT DOWN fully (not reboot), wait 15 s, power on.

  4. No "Wireless WAN" item in the BIOS at all? The unit was built without
     cellular, so the slot is switched off (common if a card was added later):
       F2 -> Main -> Kit Configuration -> password: toughkit
       Write down ALL values first. Change ONLY "Wireless WAN ID":
         FF (= none)  ->  ${wid}
            CF-20 = 13   FZ-G1 = 27   FZ-M1 = 15
            other models: copy the value from a unit of the same
            model that shipped WITH a WWAN card.
       F10 save -> SHUT DOWN fully -> power on -> repeat step 3.

  5. Card added or moved by hand? Check it is fully seated and screwed
     down, and the antenna leads are on (Main/AUX = cellular, GNSS = GPS).

  6. Re-run:  sudo ./$(basename "$0") detect
     Still nothing? Run:  sudo ./$(basename "$0") report   and send the file.
EOF
}

cmd_detect() {
  need_root detect
  hr; echo "GPS sources on this machine (read-only scan)"; hr
  local found=0 line
  while IFS= read -r line; do
    [ -z "$line" ] && continue; found=1
    IFS='|' read -r kind tty detail <<< "$line"
    case "$kind" in
      NATIVE) echo "NATIVE  $tty  $detail  -> ETC handles this itself; it wins /dev/et-gps";;
      USBGPS) echo "USBGPS  $tty  $detail  -> this add-on can feed it to ETC (priority -5)";;
      SIERRA) echo "SIERRA  $tty  $detail  -> internal modem GNSS (priority -10)";;
      SERIAL) echo "SERIAL  $tty  $detail  -> internal serial GPS (priority -15)";;
    esac
  done < <(detect_sources --probe-serial)
  [ $found -eq 0 ] && echo "No GPS found on this machine."
  # No Sierra modem on USB -> show the step-by-step checklist (even if a native
  # USB GPS is present, so the user knows why the internal one is not listed).
  usbdev_for_vid "$SIERRA_VID" >/dev/null || no_wwan_help
  echo; echo "/dev/et-gps currently -> $(etgps_target || echo 'not present')"
}

# ===========================================================================
#  Sierra modem: USB mode, ports, modem settings
# ===========================================================================
# P1/P2/P3: switch to the serial USB configuration, with retries
usb_switch_serial() {
  local dev cfg want try
  dev=$(usbdev_for_vid "$SIERRA_VID") || return 1
  want="${SIERRA_SERIAL_CFG:-$(usb_cfg_with_class "$SIERRA_VID" 255)}"
  [ -n "$want" ] || { log "Sierra: no serial USB configuration found"; return 1; }
  for try in 1 2 3 4 5; do
    cfg=$(cat "$dev/bConfigurationValue" 2>/dev/null)
    [ "$cfg" = "$want" ] && break
    log "Sierra: switching USB configuration '${cfg}' -> $want (attempt $try)"
    echo "$want" > "$dev/bConfigurationValue" 2>/dev/null || log "Sierra: write timed out (modem may be hung - P4)"
    sleep 4
  done
  sleep 3
  [ "$(cat "$dev/bConfigurationValue" 2>/dev/null)" = "$want" ]
}

# Find (and verify by probing) which modem ports are NMEA and AT
sierra_find_ports() {
  local t ifn at_ok="" nmea_ok=""
  # AT port: guess first, then any other modem port that answers OK
  for t in "$(tty_for "$SIERRA_VID" "$SIERRA_AT_IF_GUESS")" $(for x in /dev/ttyUSB*; do [ "$(prop "$x" ID_VENDOR_ID)" = "$SIERRA_VID" ] && echo "$x"; done); do
    [ -c "$t" ] || continue
    [ "$(prop "$t" ID_USB_INTERFACE_NUM)" = "00" ] && continue   # DM/diagnostic port speaks binary - never probe it
    if at_cmd "$t" 'AT' | grep -q '^OK'; then at_ok="$(prop "$t" ID_USB_INTERFACE_NUM)"; break; fi
  done
  # NMEA port: guess first; verify it streams after $GPS_START
  for t in "$(tty_for "$SIERRA_VID" "$SIERRA_NMEA_IF_GUESS")" $(for x in /dev/ttyUSB*; do [ "$(prop "$x" ID_VENDOR_ID)" = "$SIERRA_VID" ] && echo "$x"; done); do
    [ -c "$t" ] || continue
    ifn=$(prop "$t" ID_USB_INTERFACE_NUM)
    [ "$ifn" = "$at_ok" ] && continue
    [ "$ifn" = "00" ] && continue            # DM/diagnostic port: never write NMEA commands to it
    local r; r=$(nmea_probe "$t" 6 1)
    if [ "${r%% *}" -gt 0 ] 2>/dev/null; then nmea_ok="$ifn"; break; fi
  done
  SIERRA_AT_IF="${at_ok}"; SIERRA_NMEA_IF="${nmea_ok:-$SIERRA_NMEA_IF_GUESS}"
  log "Sierra ports: NMEA interface ${SIERRA_NMEA_IF} ($(sierra_nmea_port || echo '?')), AT interface ${SIERRA_AT_IF:-none} ($(sierra_at_port || echo '?'))"
  [ -n "$nmea_ok" ]
}

# GPS enable, NMEA output, firmware check, radio mode (modem settings)
sierra_configure_modem() {
  local at; at=$(sierra_at_port) || { log "Sierra: no AT port - skipping modem settings"; return 0; }
  local ati; ati=$(at_cmd "$at" 'ATI')
  log "Sierra modem: $(echo "$ati" | grep -E '^(Model|Revision):' | tr '\n' ' ')"
  case "$ati" in
    *SWI9X15C_04*) log "WARN: firmware SWI9X15C_04.xx - Panasonic has no rollover fix for 04.xx; GPS date may be wrong";;
  esac
  at_cmd "$at" 'AT!ENTERCND="A710"' >/dev/null
  local custom; custom=$(at_cmd "$at" 'AT!CUSTOM?')
  local reset=0
  if echo "$custom" | grep -Eq 'GPSENABLE[[:space:]]+0x0*[1-9a-fA-F]'; then
    log "Sierra: GPSENABLE already on ($(echo "$custom" | awk '/GPSENABLE/{print $2}')) - unchanged"
  elif echo "$custom" | grep -q 'GPSENABLE'; then
    log "Sierra: GPSENABLE is 0 - enabling"; at_cmd "$at" 'AT!CUSTOM="GPSENABLE",1' >/dev/null; reset=1
  else
    log "Sierra: GPSENABLE not listed (default/on on most firmware) - unchanged"
  fi
  if at_cmd "$at" 'AT!GPSNMEACONFIG?' | grep -q 'Enabled: 0'; then
    log "Sierra: NMEA output disabled - enabling (1 Hz)"; at_cmd "$at" 'AT!GPSNMEACONFIG=1,1' >/dev/null
  fi
  apply_radio_mode "$at"
  if [ $reset -eq 1 ]; then
    log "Sierra: resetting modem to apply GPSENABLE (re-appears in ~20 s)"
    at_cmd "$at" 'AT!RESET' >/dev/null; sleep 25
    usb_switch_serial >/dev/null 2>&1
  fi
}

# P13: cellular radio. off = AT+CFUN=0 (minimum function, GPS still works)
apply_radio_mode() {
  local at="${1:-$(sierra_at_port)}" want
  [ -n "$at" ] || return 0
  case "$RADIO_MODE" in off) want=0;; airplane) want=4;; on) want=1;; *) return 0;; esac
  local cur; cur=$(at_cmd "$at" 'AT+CFUN?' | sed -n 's/^+CFUN: *\([0-9]\).*/\1/p')
  if [ "$cur" != "$want" ]; then
    log "Sierra: radio mode '$RADIO_MODE' (AT+CFUN=$want, was ${cur:-?})"
    at_cmd "$at" "AT+CFUN=$want" >/dev/null
  fi
}

# P2: stop usb_modeswitch forcing MBIM (system file, backed up)
ums_disable_mbim() {
  [ -f "$UMS_CONF" ] || { echo "DisableMBIMGlobal=1" > "$UMS_CONF"; return; }
  [ -f "$UMS_BACKUP" ] || cp -p "${UMS_CONF}.et-orig" "$UMS_BACKUP" 2>/dev/null || cp -p "$UMS_CONF" "$UMS_BACKUP"
  if grep -qE '^[#[:space:]]*DisableMBIMGlobal' "$UMS_CONF"; then
    sed -i -E 's/^[#[:space:]]*DisableMBIMGlobal.*/DisableMBIMGlobal=1/' "$UMS_CONF"
  else
    echo "DisableMBIMGlobal=1" >> "$UMS_CONF"
  fi
  log "usb_modeswitch: DisableMBIMGlobal=1 (backup: $UMS_BACKUP)"
}

# ===========================================================================
#  Install / uninstall
# ===========================================================================
remove_old_prototype() {
  local f found=0
  for f in "${OLD_FILES[@]}"; do [ -e "$f" ] && found=1; done
  [ $found -eq 1 ] || return 0
  log "Removing earlier prototype (et-sierra-gps) files"
  systemctl disable --now et-sierra-gps-watchdog.timer 2>/dev/null
  for f in "${OLD_FILES[@]}"; do rm -f "$f"; done
  systemctl daemon-reload
}

write_conf() {
  cat > "$CONF" <<EOF
# /etc/et-internal-gps.conf - settings for the et-internal-gps add-on (v${VERSION})
# Edit, then run:  sudo ${INSTALLED_SELF} install   (re-applies everything)
#
# ---- Cellular radio (Sierra modem) ---------------------------------------
# off      = AT+CFUN=0  minimum function: radio off, lowest power. GPS works. (DEFAULT)
# airplane = AT+CFUN=4  radio off, rest of modem fully on. Try if GPS fails in 'off'.
# on       = AT+CFUN=1  radio on - only useful with a SIM/data plan.
# leave    = never change the radio setting.
# To use LTE data you need, one at a time:
#   1. RADIO_MODE="on"
#   2. MM_IGNORE="0"          (let ModemManager manage the modem again)
#   3. a SIM card + APN set up in Ubuntu's network settings
#   (GPS keeps working; the modem stays in its serial/QMI USB mode, which
#    ModemManager supports.)
RADIO_MODE="${RADIO_MODE}"

# ---- ModemManager ---------------------------------------------------------
# 1 = ModemManager ignores the modem (recommended when the radio is off).
# 0 = ModemManager may use the modem for LTE (GPS port is always ignored).
MM_IGNORE="${MM_IGNORE}"

# ---- Watchdog (every 2 minutes) --------------------------------------------
# 1 = if our GPS stops sending data, wake it (\$GPS_START) or restart gpsd the ETC way.
WATCHDOG="${WATCHDOG}"
# 1 = if gpsd has more than ETAPI_MAX_CLIENTS clients, restart ETC's et-api
#     (works around et-api 1.3.0 leaking gpsd connections while there is no fix).
ETAPI_GUARD="${ETAPI_GUARD}"
ETAPI_MAX_CLIENTS="${ETAPI_MAX_CLIENTS}"

# ---- Detected hardware (written by install - do not edit unless debugging) -
SIERRA_SERIAL_CFG="${SIERRA_SERIAL_CFG}"
SIERRA_NMEA_IF="${SIERRA_NMEA_IF}"
SIERRA_AT_IF="${SIERRA_AT_IF}"
SERIAL_GPS_TTY="${SERIAL_GPS_TTY}"
SERIAL_GPS_BAUD="${SERIAL_GPS_BAUD}"
EOF
}

write_rules() {
  local run="/usr/bin/systemd-run --no-block ${INSTALLED_SELF}"
  # --- USB mode rule (Sierra only) ---
  if [ -n "$SIERRA_SERIAL_CFG" ]; then
    {
      echo "# et-internal-gps v${VERSION} - keep the Sierra modem in its serial USB configuration (P1-P3)"
      echo "# Acts on add AND change: re-selects serial mode instantly if anything drops it."
      echo "ACTION==\"add|change\", SUBSYSTEM==\"usb\", ENV{DEVTYPE}==\"usb_device\", ATTR{idVendor}==\"${SIERRA_VID}\", ATTR{bConfigurationValue}!=\"${SIERRA_SERIAL_CFG}\", ATTR{bConfigurationValue}=\"${SIERRA_SERIAL_CFG}\""
      echo "# Backup at boot / modem reset: delayed retry helper."
      echo "ACTION==\"add\", SUBSYSTEM==\"usb\", ENV{DEVTYPE}==\"usb_device\", ATTR{idVendor}==\"${SIERRA_VID}\", RUN+=\"${run} _usbmode\""
      if [ "$MM_IGNORE" = "1" ]; then
        echo "# ModemManager: ignore the whole modem (MM_IGNORE=1 in $CONF)"
        echo "SUBSYSTEM==\"usb\", ATTR{idVendor}==\"${SIERRA_VID}\", ENV{ID_MM_DEVICE_IGNORE}=\"1\""
        echo "SUBSYSTEM==\"tty\", ENV{ID_VENDOR_ID}==\"${SIERRA_VID}\", ENV{ID_MM_DEVICE_IGNORE}=\"1\""
      fi
    } > "$RULE_USBMODE"
  else
    rm -f "$RULE_USBMODE"
  fi

  # --- GPS rules: claim /dev/et-gps with NEGATIVE priority (native wins) ---
  {
    echo "# et-internal-gps v${VERSION} - fallback GPS for ETC. ETC-native rules (priority 0) always win."
    echo "# ET_DEVICE=ETIGPS-* marks devices owned by this add-on."
    if [ -n "$SIERRA_NMEA_IF" ]; then
      echo "# Internal Sierra modem GNSS (NMEA interface ${SIERRA_NMEA_IF}) - priority -10"
      echo "SUBSYSTEM==\"tty\", ACTION==\"add\", ENV{ID_VENDOR_ID}==\"${SIERRA_VID}\", ENV{ID_USB_INTERFACE_NUM}==\"${SIERRA_NMEA_IF}\", ENV{ID_MM_PORT_IGNORE}=\"1\", ENV{ET_DEVICE}=\"ETIGPS-SIERRA\", ENV{ET_SUBDEVICE}=\"GPS\", GROUP=\"dialout\", MODE=\"0660\", SYMLINK+=\"et-gps\", OPTIONS+=\"link_priority=-10\", RUN+=\"${run} _hotplug add %k\""
    fi
    echo "# Other USB u-blox GPS not covered by ETC's rule (ETC handles 1546:01a7/01a8) - priority -5"
    echo "SUBSYSTEM==\"tty\", ACTION==\"add\", ENV{ID_VENDOR_ID}==\"${UBLOX_VID}\", ENV{ID_MODEL_ID}!=\"01a7\", ENV{ID_MODEL_ID}!=\"01a8\", ENV{ET_DEVICE}=\"ETIGPS-USB\", ENV{ET_SUBDEVICE}=\"GPS\", GROUP=\"dialout\", MODE=\"0660\", SYMLINK+=\"et-gps\", OPTIONS+=\"link_priority=-5\", RUN+=\"${run} _hotplug add %k\""
    if [ -n "$SERIAL_GPS_TTY" ]; then
      echo "# Internal serial GPS ($SERIAL_GPS_TTY @ ${SERIAL_GPS_BAUD}) - priority -15"
      echo "SUBSYSTEM==\"tty\", ACTION==\"add\", KERNEL==\"${SERIAL_GPS_TTY#/dev/}\", ENV{ET_DEVICE}=\"ETIGPS-SERIAL\", ENV{ET_SUBDEVICE}=\"GPS\", GROUP=\"dialout\", MODE=\"0660\", SYMLINK+=\"et-gps\", OPTIONS+=\"link_priority=-15\", RUN+=\"${run} _hotplug add %k\""
    fi
    echo "# Failover (P11): when ANY GPS that had /dev/et-gps is unplugged (native or ours),"
    echo "# check whether /dev/et-gps now points at one of ours and start it the ETC way."
    echo "SUBSYSTEM==\"tty\", ACTION==\"remove\", ENV{ET_SUBDEVICE}==\"GPS\", RUN+=\"${run} _hotplug remove %k\""
  } > "$RULE_GPS"
}

write_watchdog() {
  cat > "$WD_SVC" <<EOF
[Unit]
Description=et-internal-gps watchdog (fallback GPS data flow + gpsd client leak guard)
[Service]
Type=oneshot
ExecStart=${INSTALLED_SELF} _watchdog
EOF
  cat > "$WD_TMR" <<EOF
[Unit]
Description=Run et-internal-gps watchdog every 2 minutes
[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  if [ "$WATCHDOG" = "1" ] || [ "$ETAPI_GUARD" = "1" ]; then
    systemctl enable --now et-internal-gps-watchdog.timer >/dev/null 2>&1
  else
    systemctl disable --now et-internal-gps-watchdog.timer >/dev/null 2>&1
  fi
}

cmd_install() {
  need_root install
  mkdir -p "$INSTALL_DIR" "$RUN_DIR"; touch "$LOGFILE"
  log "=== $APP v$VERSION install ==="
  preflight || die "Preflight failed - fix the FAIL items above and re-run."
  remove_old_prototype

  # Copy ourselves so udev/systemd always run a known version from our own dir
  [ "$(readlink -f "$0")" != "$INSTALLED_SELF" ] && install -m 0755 "$0" "$INSTALLED_SELF"

  # --- Sierra modem ---
  if usbdev_for_vid "$SIERRA_VID" >/dev/null; then
    log "Sierra modem found: $(lsusb | grep " ${SIERRA_VID}:" | head -1)"
    SIERRA_SERIAL_CFG=$(usb_cfg_with_class "$SIERRA_VID" 255)
    if [ -z "$SIERRA_SERIAL_CFG" ]; then
      log "WARN: this Sierra model shows no serial (vendor-class) USB configuration - not supported yet. Run 'report' and send it in."
    else
      ums_disable_mbim
      write_rules   # usbmode rule first, so it can catch the post-switch drop (P3)
      udevadm control --reload-rules
      usb_switch_serial || die "Could not keep the modem in serial mode. If writes timed out, POWER OFF fully (not reboot) and re-run install."
      sleep 3
      # Pause gpsd while probing so it does not consume the test data; the udev
      # trigger at the end restarts it the ETC way (native or ours).
      systemctl stop gpsd.socket gpsd 2>/dev/null
      sierra_find_ports || log "WARN: no NMEA stream yet from interface ${SIERRA_NMEA_IF} (may need a modem reset or GPS enable - continuing)"
      sierra_configure_modem
    fi
  else
    log "No Sierra modem on USB - internal GPS cannot be set up yet (checklist below)."
    no_wwan_help
  fi

  # --- Internal serial GPS (only probed if nothing else; read-only) ---
  if [ -z "$SIERRA_NMEA_IF" ]; then
    local line; line=$(detect_sources --probe-serial | grep '^SERIAL|' | head -1)
    if [ -n "$line" ]; then
      SERIAL_GPS_TTY=$(echo "$line" | cut -d'|' -f2)
      SERIAL_GPS_BAUD=$(echo "$line" | sed -n 's/.*baud=\([0-9]*\).*/\1/p')
      log "Internal serial GPS found on $SERIAL_GPS_TTY @ $SERIAL_GPS_BAUD"
    fi
  fi

  write_conf
  write_rules
  write_watchdog
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=usb --action=change >/dev/null 2>&1
  udevadm trigger --subsystem-match=tty --action=add
  log "Installed. Waiting 15 s for udev/gpsd ..."
  sleep 15
  cmd_status
  echo
  if [ -z "$SIERRA_NMEA_IF" ] && [ -z "${SERIAL_GPS_TTY:-}" ]; then
    # Nothing internal to feed ETC. The rules stay installed (harmless) so a
    # modem enabled later in BIOS, or a non-native USB GPS, works on next boot.
    echo "Installed, but NO internal GPS was found - see the checklist above."
    echo "After fixing it, re-run: sudo ./$(basename "$0") install"
    echo "A USB GPS (u-blox VK-162 etc.) works with ETC either way."
  else
    echo "Next: ./$(basename "$0") test   (outside for a first fix: 1-15 min)"
  fi
}

cmd_uninstall() {
  need_root uninstall
  log "=== $APP uninstall ==="
  systemctl disable --now et-internal-gps-watchdog.timer >/dev/null 2>&1
  rm -f "$WD_SVC" "$WD_TMR" "$RULE_GPS" "$RULE_USBMODE"
  systemctl daemon-reload
  remove_old_prototype
  if [ -f "$UMS_BACKUP" ]; then cp -p "$UMS_BACKUP" "$UMS_CONF"; log "usb_modeswitch.conf restored"; fi
  local dev mbim
  if dev=$(usbdev_for_vid "$SIERRA_VID"); then
    mbim=$(usb_cfg_with_class "$SIERRA_VID" 2)
    [ -n "$mbim" ] && echo "$mbim" > "$dev/bConfigurationValue" 2>/dev/null && log "Sierra modem returned to MBIM configuration $mbim"
    log "Note: modem radio setting (AT+CFUN) left as is. To turn the radio on: AT+CFUN=1"
  fi
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=tty --action=add
  [ -e /dev/et-gps ] && [ ! -L /dev/et-gps ] && rm -f /dev/et-gps
  rm -f "$CONF"; rm -rf "$RUN_DIR"
  log "Removed. ($INSTALLED_SELF and $LOGFILE kept for reference; delete them by hand if you like.)"
}

# ===========================================================================
#  Runtime: called by udev (_usbmode, _hotplug) and systemd (_watchdog)
# ===========================================================================
# Boot / modem reset: make sure the modem lands in serial mode
_usbmode() { sleep 3; usb_switch_serial >/dev/null 2>&1; }

# A GPS tty appeared (add) or one disappeared (remove)
_hotplug() {
  local action="$1" kern="$2" dev tgt
  sleep 3
  tgt=$(etgps_target)
  if [ "$action" = "remove" ]; then
    sleep 2; tgt=$(etgps_target)
    if [ -z "$tgt" ] || ! is_ours "$tgt"; then exit 0; fi   # native still/again owns it, or nothing left
    log "Failover: GPS $kern removed; /dev/et-gps now -> $tgt (ours) - starting it"
    dev="$tgt"
  else
    dev="/dev/$kern"
    if [ "$tgt" != "$dev" ]; then
      log "Standing by: /dev/et-gps -> ${tgt:-none} (native/higher priority); $dev not used"
      exit 0
    fi
  fi
  [ -c "$dev" ] || exit 0                                   # P7: never create files
  if [ "$(prop "$dev" ET_DEVICE)" = "ETIGPS-SIERRA" ]; then
    apply_radio_mode
    start_gpsd_etc_way                                       # P5: gpsd first ...
    sleep 3
    printf '$GPS_START\r\n' > "$dev" 2>/dev/null             # ... then wake the stream
    log "Sierra GPS active on $dev"
  else
    start_gpsd_etc_way
    log "GPS active on $dev ($(prop "$dev" ET_DEVICE))"
  fi
}

# Every 2 minutes
_watchdog() {
  mkdir -p "$RUN_DIR"
  # P6: et-api gpsd connection leak guard (helps native GPS too)
  if [ "$ETAPI_GUARD" = "1" ]; then
    local n u; n=$(gpsd_clients)
    if [ "$n" -gt "$ETAPI_MAX_CLIENTS" ]; then
      u=$(ps -eo user:32,args | awk '/emcomm-tools-api\/bin\/[e]t-api/ {print $1; exit}')
      if [ -n "$u" ]; then
        log "Watchdog: gpsd has $n clients (> $ETAPI_MAX_CLIENTS) - restarting ETC et-api for $u (P6)"
        systemctl --user -M "${u}@" restart et-service-et-api 2>/dev/null
      fi
    fi
  fi
  [ "$WATCHDOG" = "1" ] || exit 0
  local tgt; tgt=$(etgps_target)
  [ -n "$tgt" ] && is_ours "$tgt" || exit 0                 # native device: not our business
  if ! systemctl is-active --quiet gpsd; then
    log "Watchdog: gpsd not running for $tgt - starting the ETC way"; start_gpsd_etc_way; exit 0
  fi
  # gpsd prints 3 JSON greeting lines first - read enough lines to see NMEA (bug fixed vs prototype)
  local nmea; nmea=$(timeout 8 gpspipe -r -n 20 2>/dev/null | grep -c '^\$')
  [ "${nmea:-0}" -gt 0 ] && exit 0
  if [ "$(prop "$tgt" ET_DEVICE)" = "ETIGPS-SIERRA" ]; then
    log "Watchdog: no NMEA via gpsd - waking Sierra stream on $tgt (P5)"
    printf '$GPS_START\r\n' > "$tgt" 2>/dev/null
  else
    local last=0; [ -f "$RUN_DIR/last_restart" ] && last=$(cat "$RUN_DIR/last_restart")
    if [ $(( $(date +%s) - last )) -gt 600 ]; then
      log "Watchdog: no NMEA via gpsd from $tgt - restarting gpsd the ETC way"
      date +%s > "$RUN_DIR/last_restart"; start_gpsd_etc_way
    fi
  fi
}

# ===========================================================================
#  User commands: status / test / start / radio / at / serial-mode / normal-mode
# ===========================================================================
cmd_status() {
  local tgt sdev
  hr; echo "$APP v$VERSION status"; hr
  tgt=$(etgps_target)
  if [ -n "$tgt" ]; then
    if is_ours "$tgt"; then echo "/dev/et-gps   -> $tgt  ($(prop "$tgt" ET_DEVICE), this add-on)"
    else echo "/dev/et-gps   -> $tgt  ($(prop "$tgt" ET_DEVICE) - ETC native, wins)"; fi
  elif [ -e /dev/et-gps ]; then echo "/dev/et-gps   PROBLEM: regular file (run: sudo $0 install)"
  else echo "/dev/et-gps   not present (no GPS)"; fi
  if sdev=$(usbdev_for_vid "$SIERRA_VID"); then
    echo "Sierra modem  $(cat "$sdev/product" 2>/dev/null) pid=$(cat "$sdev/idProduct") USB config='$(cat "$sdev/bConfigurationValue" 2>/dev/null)' (serial=${SIERRA_SERIAL_CFG:-?})"
    echo "  NMEA port   $(sierra_nmea_port || echo 'not present')   AT port $(sierra_at_port || echo 'not present')"
  fi
  echo "gpsd          $(systemctl is-active gpsd 2>/dev/null)  clients=$(gpsd_clients)  cpu=$(ps -o pcpu= -C gpsd | head -1 | tr -d ' ')%"
  echo "watchdog      $(systemctl is-active et-internal-gps-watchdog.timer 2>/dev/null)"
  echo "usb_modeswitch $(grep -E '^DisableMBIMGlobal' "$UMS_CONF" 2>/dev/null || echo 'DisableMBIMGlobal not set')"
  echo "settings      RADIO_MODE=$RADIO_MODE MM_IGNORE=$MM_IGNORE WATCHDOG=$WATCHDOG ETAPI_GUARD=$ETAPI_GUARD"
  local f; for f in "$INSTALLED_SELF" "$CONF" "$RULE_GPS" "$RULE_USBMODE" "$WD_TMR"; do
    [ -e "$f" ] && echo "file          $f" || echo "file          $f  (missing)"
  done
}

cmd_test() {
  hr; echo "$APP v$VERSION test"; hr
  echo "== NMEA through gpsd (8 s): \$G.. lines; fields fill in once there is a fix"
  timeout 8 gpspipe -r -n 20 2>&1 | grep -E '^\$G' | head -6 || echo "   none"
  echo "== Decoded: mode 1 = no fix, 2 = 2D, 3 = 3D"
  local tpv; tpv=$(timeout 10 gpspipe -w -n 15 2>/dev/null | grep -m1 '"class":"TPV"')
  echo "   ${tpv:-no TPV report}" | cut -c1-200
  local d; d=$(echo "$tpv" | sed -n 's/.*"time":"\([0-9-]*\)T.*/\1/p')
  if [ -n "$d" ]; then
    [ "$d" = "$(date -u +%F)" ] && echo "   GPS date OK ($d)" \
      || echo "   GPS DATE WRONG ($d) - GPS week rollover (P12). Panasonic fix: 'Tool for Sierra's Wireless WAN GPS Week Rollover issue'"
  fi
  echo "== ETC view:  $(timeout 15 "$ET_SYSINFO" et-gps 2>&1)   grid: $(timeout 15 "$ET_SYSINFO" grid 2>&1)"
  echo "== Time source: $(chronyc sources 2>/dev/null | grep -i NMEA || echo 'NMEA not listed')"
  echo "== gpsd: clients=$(gpsd_clients) cpu=$(ps -o pcpu= -C gpsd | head -1 | tr -d ' ')%"
  echo "Live view: cgps -s   (q to quit). First fix outdoors: 1-15 min."
}

cmd_start() {
  need_root start
  local tgt; tgt=$(etgps_target) || true
  [ -n "$tgt" ] || die "/dev/et-gps not present"
  _hotplug add "$(basename "$tgt")"
}

cmd_radio() {
  need_root radio
  local at; at=$(sierra_at_port) || die "No Sierra AT port (run install first)"
  case "${1:-status}" in
    off|airplane|on) RADIO_MODE="$1"; apply_radio_mode "$at"
      [ -f "$CONF" ] && sed -i "s/^RADIO_MODE=.*/RADIO_MODE=\"$1\"/" "$CONF";;
    status) ;;
    *) die "usage: radio off|airplane|on|status";;
  esac
  echo "Radio: $(at_cmd "$at" 'AT+CFUN?' | grep CFUN)  (0=off, 4=airplane, 1=on)"
}

cmd_at() {
  need_root at
  local at; at=$(sierra_at_port) || die "No Sierra AT port"
  [ -n "${1:-}" ] || die "usage: at 'AT...'"
  at_cmd "$at" "$1"
}

cmd_serial_mode() { need_root serial-mode; ums_disable_mbim; usb_switch_serial && echo "Serial mode OK" || echo "Failed - see: sudo dmesg | tail -30"; }
cmd_normal_mode() {
  need_root normal-mode
  rm -f "$RULE_USBMODE"; udevadm control --reload-rules
  local dev mbim; dev=$(usbdev_for_vid "$SIERRA_VID") || die "No Sierra modem"
  mbim=$(usb_cfg_with_class "$SIERRA_VID" 2); [ -n "$mbim" ] && echo "$mbim" > "$dev/bConfigurationValue"
  echo "Modem in MBIM (data-only) configuration ${mbim:-?}. Re-run install to restore GPS."
}

# ===========================================================================
#  report: ONE redacted file with everything needed for remote support
# ===========================================================================
redact() {
  if [ "${FULL:-0}" = "1" ]; then cat; return; fi
  sed -E \
    -e 's/("lat":-?[0-9]+\.[0-9]{2})[0-9]+/\1/g' \
    -e 's/("lon":-?[0-9]+\.[0-9]{2})[0-9]+/\1/g' \
    -e 's/(-?[0-9]{1,3}\.[0-9]{2})[0-9]{3,},(-?[0-9]{1,3}\.[0-9]{2})[0-9]{3,}/\1xx,\2xx/g' \
    -e 's/,([0-9]{2})[0-9]{2}\.[0-9]+,([NS]),([0-9]{3})[0-9]{2}\.[0-9]+,([EW])/,\1xx.xx,\2,\3xx.xx,\4/g' \
    -e 's/(IMEI[^0-9]*)[0-9]{10,}/\1<redacted>/I' \
    -e 's/((MEID|ESN|IMSI|CIMI|ICCID)[^0-9A-F]*)[0-9A-F]{8,}/\1<redacted>/I' \
    -e 's/(FSN:? *)[A-Z0-9]{6,}/\1<redacted>/I' \
    -e 's/(Serial ?Number:? *).*/\1<redacted>/I' \
    -e 's/(grid: *)[A-R]{2}[0-9]{2}[a-x]{2}/\1<redacted>/'
}
rsec() { printf '\n==================== %s ====================\n' "$*"; }
rrun() { printf '\n$ %s\n' "$*"; timeout 25 bash -c "$*" 2>&1 || printf '(exit %s)\n' "$?"; }

report_snapshot() {
  rsec "SNAPSHOT: $1 ($(date '+%F %T %Z'))"
  rsec "1. System"
  rrun "hostnamectl 2>/dev/null | grep -Ev 'Machine ID|Boot ID'; uname -r; uptime"
  rrun "dmidecode -s system-product-name; dmidecode -s bios-version; dmidecode -s bios-release-date"
  rrun "$ET_SYSINFO release 2>/dev/null; dpkg-query -W gpsd chrony usb-modeswitch modemmanager 2>/dev/null"
  rrun "timedatectl 2>/dev/null | grep -E 'Local time|Time zone|synchronized|NTP'"
  rsec "2. USB"
  rrun "lsusb"; rrun "lsusb -t"
  local sdev; if sdev=$(usbdev_for_vid "$SIERRA_VID"); then
    echo "Sierra sysfs $sdev pid=$(cat "$sdev/idProduct") cfg='$(cat "$sdev/bConfigurationValue" 2>/dev/null)' nconf=$(cat "$sdev/bNumConfigurations" 2>/dev/null) power=$(cat "$sdev/power/control" 2>/dev/null)"
    rrun "lsusb -v -d ${SIERRA_VID}: 2>/dev/null | grep -E 'bConfigurationValue|bNumInterfaces|bInterfaceNumber|bInterfaceClass'"
  fi
  rsec "3. Serial ports"
  rrun "ls -l /dev/serial/by-id/ /dev/ttyUSB* /dev/ttyACM* 2>&1"
  local t; for t in /dev/ttyUSB* /dev/ttyACM*; do [ -e "$t" ] || continue
    echo "--- $t"; udevadm info -q property -n "$t" 2>/dev/null | grep -E '^(ID_VENDOR_ID|ID_MODEL_ID|ID_MODEL=|ID_USB_INTERFACE_NUM|ID_USB_DRIVER|DEVLINKS|ET_DEVICE|ET_SUBDEVICE|ID_MM_)'
  done
  rsec "4. /dev/et-gps"
  rrun "ls -l /dev/et-gps; readlink -f /dev/et-gps; ls -l /run/udev/links/*et-gps* 2>/dev/null || ls -lR /run/udev/links 2>/dev/null | grep -A3 et-gps"
  rsec "5. Add-on files and settings"
  rrun "ls -l $INSTALL_DIR $CONF $RULE_GPS $RULE_USBMODE $WD_SVC $WD_TMR 2>&1; sha256sum $INSTALLED_SELF 2>/dev/null"
  rrun "grep -v '^#' $CONF 2>/dev/null | grep -v '^$'"
  rrun "cat $RULE_USBMODE $RULE_GPS 2>/dev/null | grep -v '^#'"
  rrun "ls -l /etc/udev/rules.d/ | grep -Ei 'et-|sierra|blox'"
  rrun "grep -E '^[#[:space:]]*(DisableMBIMGlobal|DisableSwitching)' $UMS_CONF"
  rsec "6. gpsd"
  rrun "systemctl is-active gpsd gpsd.socket et-internal-gps-watchdog.timer; grep -v '^#' $ET_GPSD_DEFAULT | grep -v '^$'"
  rrun "ps -o pid,etime,pcpu,args -C gpsd"
  echo "gpsd clients: $(gpsd_clients)"
  rrun "ss -Htnp state established '( dport = :2947 )' | grep -o 'users:((\"[^\"]*\"' | sort | uniq -c"
  rrun "timeout 10 gpspipe -w -n 15 | grep -E '\"class\":\"(DEVICES|TPV|SKY)\"' | head -5"
  rrun "timeout 8 gpspipe -r -n 20 | grep '^\\\$' | head -10"
  rsec "7. Sierra modem (read-only AT queries)"
  local at; if at=$(sierra_at_port); then
    echo "AT port $at   NMEA port $(sierra_nmea_port || echo none)"
    for q in 'ATI' 'AT+CFUN?' 'AT!GPSSTATUS?' 'AT!GPSNMEACONFIG?'; do echo ">> $q"; at_cmd "$at" "$q" | grep -v '^$'; done
    at_cmd "$at" 'AT!ENTERCND="A710"' >/dev/null; echo ">> AT!CUSTOM? (GPS/NMEA/USB/CFUN)"; at_cmd "$at" 'AT!CUSTOM?' | grep -Ei 'GPS|NMEA|USB|CFUN'
  else echo "No Sierra AT port."; fi
  rsec "8. Time / ETC view / services"
  rrun "chronyc sources 2>&1"
  # Run ETC's own view as the desktop user: et-system-info reads that user's
  # ~/.config/emcomm-tools/user.json, which root does not have.
  local asuser=()
  [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ] && asuser=(sudo -u "$SUDO_USER" -H)
  echo "et-system-info et-gps : $(timeout 15 ${asuser[@]+"${asuser[@]}"} "$ET_SYSINFO" et-gps 2>&1)"
  echo "et-system-info grid   : $(timeout 15 ${asuser[@]+"${asuser[@]}"} "$ET_SYSINFO" grid 2>&1)"
  rrun "ps -eo pid,etime,args | grep -E '[c]onky|[e]t-api|[M]odemManager'"
  rsec "9. Logs"
  rrun "dmesg | grep -Ei 'qcserial|qmi_wwan|cdc_mbim|cdc_acm|usb_modeswitch|sets config|error -110|u-blox|1199|apparmor=\"DENIED\".*gpsd.*et-gps' | tail -40"
  rrun "journalctl -b -u gpsd --no-pager | tail -20"
  rrun "journalctl -b -t $APP --no-pager | tail -40"
  rrun "tail -30 $LOGFILE"
}

report_findings() {
  rsec "FINDINGS ($(date '+%T'))"
  local sdev cfg want tgt n
  if sdev=$(usbdev_for_vid "$SIERRA_VID"); then
    cfg=$(cat "$sdev/bConfigurationValue" 2>/dev/null); want=$(usb_cfg_with_class "$SIERRA_VID" 255)
    echo "INFO  Sierra modem $(cat "$sdev/product" 2>/dev/null) ($(cat "$sdev/idProduct"))"
    if [ -z "$cfg" ]; then echo "FAIL  Sierra UNCONFIGURED (blank). If 'error -110' in logs: full POWER OFF, then install (P4)"
    elif [ -n "$want" ] && [ "$cfg" != "$want" ]; then echo "FAIL  Sierra in data-only config $cfg (serial is $want) - run install (P1)"
    else echo "PASS  Sierra in serial config $cfg"; fi
    sierra_nmea_port >/dev/null && echo "PASS  Sierra NMEA port $(sierra_nmea_port)" || echo "FAIL  Sierra NMEA port missing"
    dmesg | grep -q 'error -110' && echo "WARN  'error -110' (modem timeouts) since boot - power off fully if GPS is missing (P4)"
  else
    echo "INFO  no Sierra modem on USB - checklist:"
    no_wwan_help
  fi
  grep -qE '^DisableMBIMGlobal=1' "$UMS_CONF" 2>/dev/null && echo "PASS  usb_modeswitch MBIM check disabled" \
    || { [ -n "${sdev:-}" ] && echo "WARN  usb_modeswitch may force MBIM (P2)"; }
  # Version stamp is written into the rule header as "et-internal-gps vYYYY.MM.DD-HHMM".
  # Match that exact token (a plain "v..." match also hits words like "native").
  if [ -f "$RULE_GPS" ]; then
    local iv; iv=$(grep -o 'et-internal-gps v[0-9][0-9.-]*' "$RULE_GPS" | head -1 | sed 's/.* v//')
    echo "PASS  add-on installed (v${iv:-unknown})"
    [ -n "$iv" ] && [ "$iv" != "$VERSION" ] && \
      echo "WARN  installed v$iv but this script is v$VERSION - re-run: sudo ./et-internal-gps.sh install"
  else
    echo "INFO  add-on not installed"
  fi
  for f in "${OLD_FILES[@]}"; do [ -e "$f" ] && echo "WARN  old prototype file present: $f (install removes it)"; done
  tgt=$(etgps_target)
  if [ -n "$tgt" ]; then
    is_ours "$tgt" && echo "INFO  /dev/et-gps -> $tgt ($(prop "$tgt" ET_DEVICE), add-on)" \
                   || echo "INFO  /dev/et-gps -> $tgt ($(prop "$tgt" ET_DEVICE), ETC native - wins)"
  elif [ -e /dev/et-gps ]; then echo "FAIL  /dev/et-gps is a regular file (P7) - run install"
  else echo "FAIL  /dev/et-gps missing"; fi
  if systemctl is-active --quiet gpsd; then
    n=$(gpsd_clients); echo "PASS  gpsd running (clients $n, cpu $(ps -o pcpu= -C gpsd | head -1 | tr -d ' ')%)"
    [ "$n" -gt "$ETAPI_MAX_CLIENTS" ] && echo "WARN  $n gpsd clients - et-api leak (P6); watchdog restarts et-api"
    local nm; nm=$(timeout 8 gpspipe -r -n 20 2>/dev/null | grep -c '^\$')
    [ "${nm:-0}" -gt 0 ] && echo "PASS  NMEA flowing through gpsd" || echo "FAIL  no NMEA through gpsd (Sierra: sudo $0 start) (P5)"
    local tpv; tpv=$(timeout 10 gpspipe -w -n 15 2>/dev/null | grep -m1 '"class":"TPV"')
    case "$(echo "$tpv" | sed -n 's/.*"mode":\([0-9]\).*/\1/p')" in
      3) echo "PASS  3D fix";; 2) echo "PASS  2D fix";; 1) echo "INFO  no fix yet (needs sky view)";; *) echo "WARN  no TPV";;
    esac
    local d; d=$(echo "$tpv" | sed -n 's/.*"time":"\([0-9-]*\)T.*/\1/p')
    [ -n "$d" ] && { [ "$d" = "$(date -u +%F)" ] && echo "PASS  GPS date correct" || echo "FAIL  GPS date $d wrong - rollover (P12)"; }
  else
    echo "FAIL  gpsd not running"
  fi
  [ "$(pgrep -c -x conky)" -gt 1 ] && echo "WARN  $(pgrep -c -x conky) conky panels running (doubles ETC's GPS/grid polling; not caused by this add-on - log out/in or reboot to clear)"
  timedatectl 2>/dev/null | grep -q 'synchronized: no' && echo "WARN  system clock not synchronized"
}

cmd_report() {
  need_root report
  local mode="snapshot"; FULL=0
  for a in "$@"; do case "$a" in --full) FULL=1;; --hotplug) mode="hotplug";; esac; done
  local user="${SUDO_USER:-root}" home; home=$(getent passwd "$user" | cut -d: -f6)
  local out="${home:-/root}/${APP}-report-$(hostname)-$(date +%Y%m%d-%H%M%S).log"
  { echo "$APP v$VERSION report  mode=$mode  redaction=$([ "$FULL" = 1 ] && echo off || echo on)"
    echo "Generated $(date -Is) on $(hostname)"; } > "$out"
  if [ "$mode" = "snapshot" ]; then
    echo "Collecting (1-2 min) ..."
    { report_snapshot "current"; report_findings; } 2>&1 | redact >> "$out"
  else
    local before after
    read -r -p "Step 1/3: UNPLUG any USB GPS, then press Enter ... " _
    { report_snapshot "BEFORE USB GPS"; report_findings; } 2>&1 | redact >> "$out"; before=$(lsusb)
    read -r -p "Step 2/3: PLUG IN the USB GPS, then press Enter ... " _
    echo "Waiting 25 s ..."; sleep 25; after=$(lsusb)
    { rsec "NEW USB DEVICES AFTER PLUG-IN"; diff <(echo "$before") <(echo "$after") | grep '^>' \
        || echo "NONE - the computer did not see the device (try a hub/other port/cable) (P14)"; } >> "$out"
    { report_snapshot "WITH USB GPS"; report_findings; } 2>&1 | redact >> "$out"
    read -r -p "Step 3/3: UNPLUG the USB GPS, then press Enter ... " _
    echo "Waiting 150 s (failover + one watchdog run) ..."; sleep 150
    { report_snapshot "AFTER UNPLUG"; report_findings; } 2>&1 | redact >> "$out"
  fi
  chown "$user": "$out" 2>/dev/null
  echo; grep -E '^(PASS|INFO|WARN|FAIL)  ' "$out" | tail -25
  echo; echo "Report: $out"; echo "Send that ONE file back for help."
}

# ===========================================================================
#  compare: side-by-side precision test of every GPS source present
# ===========================================================================
cmd_compare() {
  need_root compare
  local dur="${1:-300}" ports=() kinds=() t
  t=$(sierra_nmea_port) && { ports+=("$t"); kinds+=("S"); }
  for t in /dev/ttyACM* /dev/ttyUSB*; do
    [ -e "$t" ] && [ "$(prop "$t" ID_VENDOR_ID)" = "$UBLOX_VID" ] && { ports+=("$t"); kinds+=("U"); }
  done
  [ "${#ports[@]}" -ge 2 ] || die "Need 2 GPS sources (found: ${ports[*]:-none})"
  local user="${SUDO_USER:-root}" home; home=$(getent passwd "$user" | cut -d: -f6)
  local out="${home:-/root}/${APP}-compare-$(hostname)-$(date +%Y%m%d-%H%M%S).log"
  log "compare: ${ports[*]} for ${dur}s (gpsd paused)"
  trap 'systemctl start gpsd.socket 2>/dev/null; start_gpsd_etc_way; sleep 3; t=$(sierra_nmea_port) && printf "\$GPS_START\r\n" > "$t"; chown "'"$user"'": "'"$out"'" 2>/dev/null; echo "gpsd restored"' EXIT
  systemctl stop gpsd.socket gpsd 2>/dev/null; pkill -x gpsd 2>/dev/null; sleep 1
  python3 - "$dur" "$out" "${ports[@]}" "--kinds" "${kinds[@]}" <<'PY'
import os, sys, time, select, termios, math, statistics as st
args = sys.argv[1:]; dur = int(args[0]); out = args[1]
k = args.index("--kinds"); ports = args[2:k]; kinds = args[k+1:]
name = {p: ("Sierra (internal) " if kd == "S" else "USB GPS ") + p for p, kd in zip(ports, kinds)}
def opn(p, start):
    fd = os.open(p, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    a = termios.tcgetattr(fd); a[0]=a[1]=a[3]=0; a[2]=termios.CS8|termios.CREAD|termios.CLOCAL
    a[4]=a[5]=termios.B9600; termios.tcsetattr(fd, termios.TCSANOW, a)
    if start: os.write(fd, b"$GPS_START\r\n")
    return fd
fds = {opn(p, kd == "S"): p for p, kd in zip(ports, kinds)}
buf = {fd: b"" for fd in fds}; samples = {p: [] for p in ports}; inview = {p: {} for p in ports}
def dm(v, h):
    if not v: return None
    d = int(float(v)/100); x = d + (float(v)-d*100)/60
    return -x if h in "SW" else x
def ok(s):
    if not s.startswith("$") or "*" not in s: return False
    b, c = s[1:].split("*", 1); x = 0
    for ch in b: x ^= ord(ch)
    try: return x == int(c[:2], 16)
    except ValueError: return False
def pump(t):
    r, _, _ = select.select(list(fds), [], [], t); res = []
    for fd in r:
        try: buf[fd] += os.read(fd, 4096)
        except OSError: continue
        while b"\n" in buf[fd]:
            raw, buf[fd] = buf[fd].split(b"\n", 1); s = raw.decode("ascii", "replace").strip()
            if not ok(s): continue
            f = s.split("*")[0].split(","); p = fds[fd]
            if f[0][3:] == "GSV" and len(f) > 3: inview[p][f[0][1:3]] = int(f[3] or 0)
            if f[0][3:] == "GGA" and len(f) > 9:
                try: res.append((p, int(f[6] or 0), int(f[7] or 0), float(f[8] or "nan"), dm(f[2], f[3]), dm(f[4], f[5]), float(f[9] or "nan")))
                except ValueError: pass
    return res
print("Warm-up: waiting for every receiver to have a fix (max 15 min)...", flush=True)
have = {p: False for p in ports}; t0 = time.time(); lp = 0
while not all(have.values()) and time.time() - t0 < 900:
    for g in pump(1):
        have[g[0]] = g[1] > 0 and g[4] is not None
    if time.time() - lp > 15:
        lp = time.time(); print("  %4ds " % (time.time()-t0) + "  ".join("%s:%s" % (name[p].split()[0], "FIX" if have[p] else "..") for p in ports), flush=True)
print("Recording %ds..." % dur, flush=True); end = time.time() + dur
while time.time() < end:
    for g in pump(1): samples[g[0]].append(g)
def pc(a, q):
    a = sorted(a); i = int((len(a)-1)*q); return a[i]
L = ["%s compare  %ds  (offsets in metres; no coordinates)" % ("et-internal-gps", dur), "",
     "%-34s %6s %7s %5s %6s %6s %6s %6s %7s" % ("Receiver","epochs","fix%","sats","HDOP","CEP50","CEP95","max","alt sd")]
means = {}
for p in ports:
    s = samples[p]; fx = [x for x in s if x[1] > 0 and x[4] is not None]
    if not fx: L.append("%-34s %6d  no fixes" % (name[p], len(s))); continue
    la = st.mean(x[4] for x in fx); lo = st.mean(x[5] for x in fx); means[p] = (la, lo)
    kx = 111320*math.cos(math.radians(la)); r = [math.hypot((x[5]-lo)*kx, (x[4]-la)*110540) for x in fx]
    al = [x[6] for x in fx if x[6] == x[6]]
    L.append("%-34s %6d %6.1f%% %5.1f %6.2f %5.1fm %5.1fm %5.1fm %6.1fm" % (name[p], len(s), 100*len(fx)/max(len(s),1),
             st.mean(x[2] for x in fx), st.mean(x[3] for x in fx), pc(r,.5), pc(r,.95), max(r), st.pstdev(al) if len(al) > 1 else 0))
    L.append("%-34s in view: %s" % ("", inview[p]))
ks = list(means)
for i in range(len(ks)):
    for j in range(i+1, len(ks)):
        (a1,o1),(a2,o2) = means[ks[i]], means[ks[j]]
        L.append("Distance between averages %s <-> %s: %.1f m" % (ks[i], ks[j], math.hypot((o2-o1)*111320*math.cos(math.radians(a1)), (a2-a1)*110540)))
L += ["", "Lower HDOP/CEP and more sats = better. Measures precision and agreement, not absolute accuracy."]
print("\n".join(L)); open(out, "w").write("\n".join(L) + "\n"); print("Saved: " + out)
PY
}

cmd_help() { sed -n '2,40p' "$0"; }

# ===========================================================================
#  Main
# ===========================================================================
[ "${1:-}" != "_watchdog" ] && [ "${1:-}" != "_hotplug" ] && [ "${1:-}" != "_usbmode" ] && echo "$APP v$VERSION"
case "${1:-help}" in
  version|-v|--version) ;;
  help|-h|--help) cmd_help ;;
  detect)      cmd_detect ;;
  install)     cmd_install ;;
  uninstall)   cmd_uninstall ;;
  status)      cmd_status ;;
  test)        cmd_test ;;
  start)       cmd_start ;;
  radio)       shift; cmd_radio "${1:-status}" ;;
  at)          shift; cmd_at "${1:-}" ;;
  report)      shift; cmd_report "$@" ;;
  compare)     shift; cmd_compare "${1:-300}" ;;
  serial-mode) cmd_serial_mode ;;
  normal-mode) cmd_normal_mode ;;
  _usbmode)    _usbmode ;;
  _hotplug)    shift; _hotplug "$@" ;;
  _watchdog)   _watchdog ;;
  *) echo "Unknown command '$1'. Try: $0 help"; exit 1 ;;
esac
