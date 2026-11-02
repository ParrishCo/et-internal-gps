# et-internal-gps — use your Toughbook's built-in GPS with EmComm Tools

Version 2026.11.02-1620 · for EmComm Tools (ETC) R7 · by Andrew (Drew) K2RHL

Many Panasonic Toughbooks/Toughpads (FZ-M1, FZ-G1, CF-20 …) with an LTE option
have a GPS receiver **inside the Sierra Wireless LTE modem**. ETC does not use it
out of the box. This add-on makes it work with ETC automatically — and steps
aside whenever you plug in a USB GPS that ETC supports natively.

* ETC-native GPS (e.g. u-blox VK-162/VK-172) **always wins**
* No USB GPS? The built-in GPS is used automatically (plug-and-play)
* Cellular radio is switched **off** (lowest power) — GPS still works
* Never edits ETC files; `uninstall` removes everything
* One-file support report you can send back if something is wrong

## Install

Copy `et-internal-gps.sh` to the computer (USB stick or `scp`), then:

```bash
chmod +x et-internal-gps.sh
sudo ./et-internal-gps.sh detect      # what GPS hardware is here? (changes nothing)
sudo ./et-internal-gps.sh install     # set it up
./et-internal-gps.sh test             # take it outside: first fix 1–15 min
```

## Everyday commands

| Command | What it does |
|---|---|
| `./et-internal-gps.sh status` | Which GPS ETC is using, health of gpsd/watchdog |
| `./et-internal-gps.sh test` | GPS data, fix, date check, ETC view, time source |
| `sudo ./et-internal-gps.sh report` | **Creates one file to send back for help** |
| `sudo ./et-internal-gps.sh report --hotplug` | Guided test: plug/unplug a USB GPS |
| `sudo ./et-internal-gps.sh compare` | 5-min side-by-side accuracy test (needs 2 GPS) |
| `sudo ./et-internal-gps.sh radio off\|airplane\|on` | Cellular radio power |
| `sudo ./et-internal-gps.sh uninstall` | Remove everything |

## If something is wrong

Run `sudo ./et-internal-gps.sh report` and send the file it names
(`~/et-internal-gps-report-<computer>-<date>.log`). Your location is rounded
to ~1 km and serial numbers, IMEI/MEID and SIM numbers are hidden.

If no LTE/GPS modem is found, `detect`, `install` and `report` print a
numbered checklist right in the terminal (label check, BIOS settings, the
Kit Configuration value for your model, antenna leads). The short version:

Common fixes the report will point you to:

* **No modem found** but the label under the battery shows an IMEI →
  BIOS (F2) → *Wireless WAN* = **Enabled**.
* **You added an LTE/GPS card** to a unit built without one, and BIOS has no
  *Wireless WAN* item → BIOS (F2) → **Main → Kit Configuration** (Panasonic
  service password `toughkit`) → **Wireless WAN ID** from `FF` to the
  value for your model → F10 save → full shut down → power on.

  | Model | Wireless WAN ID |
  |---|---|
  | CF-20 Mk2 | `13` (tested with EM7455) |
  | FZ-G1 Mk5 | `27` |
  | FZ-M1 Mk2 | `15` |

  Write down the original values first and change only that one
  field. Other cards/models may need another ID: copy it from a unit of the
  same model that shipped with that card.
* **Modem stuck / "error -110"** → shut down completely (not reboot),
  wait 15 s, power on, run `install` again.
* **Wrong GPS date** (position fine) → old modem firmware (2019 GPS week
  rollover). Panasonic's free Windows tool fixes it:
  *"Tool for Sierra's Wireless WAN GPS Week Rollover issue"*.
* **USB GPS not seen** on an FZ-M1 → try it through a USB hub.

## Settings

`/etc/et-internal-gps.conf` (commented). Change, then re-run
`sudo /opt/et-internal-gps/et-internal-gps.sh install`.
To use LTE data instead of radio-off: `RADIO_MODE="on"` and `MM_IGNORE="0"`,
then a SIM + APN in Ubuntu network settings.

## Tested on

| Unit | Modem | Firmware | Result |
|---|---|---|---|
| FZ-M1 Mk2 (FZ-M1F150XVJ, Japan) | EM7330 (1199:9041) | SWI9X15C_05.05.26.00 | 3D fix in ~4 min, correct date, 25 sats in view (GPS+GLONASS), CEP50 0.6 m; u-blox 7 hand-over both ways OK |
| CF-20 Mk2 (CF-20G1165VM, card added; Kit Config Wireless WAN ID 13) | EM7455B (1199:9071) | SWI9X30C_02.24.05.06 | Already in serial config (no switch needed); 3D fix in 212 s, correct date, 11 sats used (GPS+GLONASS), HDOP 1.0; radio off; survives reboot |

Please send a `report` from other models so this table can grow.

## Also in this package

* `et-barcode-test.sh` — separate, temporary barcode-scanner test (changes nothing).
