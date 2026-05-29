# QDtech MPI5006 Touch Fix for Victron Cerbo GX (Venus OS)

Fixes touch input — and the Brief-page sleep button — for the **QDtech MPI5001 / MPI5006** 5-inch HDMI touchscreen on a **Victron Cerbo GX** running Venus OS with the Qt6-based GUI (venus-gui-v2).

---

## Problem 1: touch lands at the bottom-right corner

The display image works over HDMI, but touch does not respond — or every touch appears stuck at the bottom-right corner of the screen.

**Root cause:** The `hid-generic` kernel driver maps `ABS_X`/`ABS_Y` from the last finger slot in the HID descriptor (Finger 3), which is always inactive and always reports the maximum coordinates (800, 480).

**Solution:** `touch-bridge.py` locates the device dynamically by USB VID:PID (`0484:5750`), grabs its event node exclusively, reads raw HID reports from its hidraw node, parses Finger 1's correct X/Y coordinates, and forwards them through a uinput virtual touchscreen named "MPI5001 Touch Bridge".

## Problem 2: the moon/zZ sleep button does nothing

The Victron GUI shows a moon-and-zZ button in the top-right of the status bar on the Brief page. Tapping it calls `ScreenBlanker.setDisplayOff()`, which writes `1` to the file pointed at by `/etc/venus/blank_display_device`. On a Cerbo with a built-in panel that path is a backlight sysfs node; on HDMI it's missing or non-functional, so the button does nothing.

**Solution:** [ldenisey/venus-os-configuration](https://github.com/ldenisey/venus-os-configuration)'s `blank-display-device` package, plus a small patch to make it discover the touch-bridge by sysfs name (because Venus OS does not tag input devices with `ID_INPUT_TOUCHSCREEN=1`, so the package's default auto-detect can't find anything).

The package's daemon turns HDMI off via `/sys/class/drm/card0-HDMI-A-1/status` and — crucially — once blanked it stops listening to anything the GUI writes and only wakes up on a real `access` event on the touchscreen input device. That breaks the auto-blank-then-immediately-wake-up cycle that Qt6/EGLFS would otherwise produce.

---

## Hardware

| Component | Details |
|-----------|---------|
| Display | QDtech MPI5001 / MPI5006 (5-inch, 800×480) |
| Touch controller | USB HID, VID:PID `0484:5750` |
| System | Victron Cerbo GX, Venus OS ≥ 3.x (GUI v2 / Qt6) |
| Connection | HDMI (video) + USB (touch) |
| 3D printed case | [MakerWorld — 5-inch touch display MPI5006 QDtech](https://makerworld.com/en/models/2854959-5-inch-touch-display-mpi5006-qdtech#profileId-3185045) — attaches to a wall or car interior panel with 3M VHB tape |
| Recommended cables | Flat HDMI and flat USB-C for clean routing in tight spaces |

---

## Installation

### 1. Copy files to the Cerbo GX

SSH in as root (no password by default on Venus OS):

```sh
scp touch-bridge.py rc.local install-sleep-button.sh root@<cerbo-ip>:/data/
ssh root@<cerbo-ip>
```

Or paste them with `cat > /data/<file> << 'EOF' ... EOF` if scp is inconvenient.

### 2. Make the boot script executable

```sh
chmod +x /data/rc.local
```

`/etc/init.d/custom-rc-late.sh` (built into Venus OS) runs `/data/rc.local` at startup if it's executable. The `/data/` partition persists across reboots and firmware updates.

### 3. Install the sleep-button package

```sh
sh /data/install-sleep-button.sh
```

This:

- installs `blank-display-device` from ldenisey's feed
- patches `/opt/victronenergy/blank-display-device/blank-display-device.sh` to find the touch-bridge by sysfs name
- installs `mod-persist` and registers `blank-display-device` so it survives Venus OS firmware updates
- restarts the daemon and the GUI

### 4. Reboot

```sh
reboot
```

After reboot:

- touch should work everywhere in the GUI
- the moon icon on the Brief page should blank the HDMI output
- any tap on the (black) screen wakes it back up

Verify the touch bridge:

```sh
ps | grep touch-bridge
```

Verify the sleep daemon:

```sh
tail -n 10 /var/log/blank-display-device/current
# should end with:
#   HDMI: /sys/class/drm/card0-HDMI-A-1/status
#   Touch: /dev/input/event3
```

---

## Files

| File | Description |
|------|-------------|
| `touch-bridge.py` | hidraw → uinput touch bridge — dynamic device discovery, USB reconnect, optional auto-blank |
| `rc.local` | `/data/rc.local`: starts the touch bridge at boot **and** re-applies the daemon patch if a firmware update has reverted it |
| `install-sleep-button.sh` | one-shot installer for the sleep-button shim |

---

## Surviving firmware updates

`mod-persist` re-installs the `.ipk` packages after each Venus OS firmware update. But the patched daemon script (`/opt/victronenergy/blank-display-device/blank-display-device.sh`) is restored to its upstream version, which can't find the touchscreen on Venus OS.

`rc.local` handles this: on every boot it checks whether the script already contains the string `MPI5001 Touch Bridge`. If not, it rewrites it with the sysfs-lookup version and bounces the service.

---

## Troubleshooting

### Touch doesn't work after reboot

```sh
ps | grep touch-bridge        # the python process should be running
ls -la /data/rc.local         # must be executable
cat /proc/bus/input/devices   # event3 should be "MPI5001 Touch Bridge"
```

### Sleep button does nothing

```sh
cat /etc/venus/blank_display_device          # should print /etc/venus/blank_display_device.value
cat /etc/venus/blank_display_device.value    # 0 = on, 1 = off

# Daemon log (daemontools tai64n timestamps; pipe through tai64nlocal for readable times)
tail -n 30 /var/log/blank-display-device/current
```

If the daemon log ends with `Error: ... not found`, the touch bridge wasn't running yet when the daemon started. Re-apply rc.local's restart logic by hand:

```sh
svc -u /service/blank-display-device
```

### Display turns itself back on right after blanking

This was the original symptom of the naive "watcher writes to fb0/blank" approach — Qt6/EGLFS takes precedence over fbdev, and ScreenBlanker auto-wakes on any input event from the disconnect. The ldenisey daemon avoids this by ignoring everything the GUI writes once it has blanked the screen; it only unblanks on a real `inotifywait -e access` on the touchscreen device. If you see cycling, your daemon is either unpatched (running the upstream `udevadm`-based detection that finds nothing) or watching the wrong input device.

### Wrong device nodes

`touch-bridge.py` finds the correct `event*` and `hidraw*` nodes automatically by searching `/sys/bus/usb/devices/` for the device with VID:PID `0484:5750`. No manual adjustment needed — works even if node numbers change after reboot or if other USB devices are added.

If the device is not found at all:

```sh
ls /dev/hidraw*
cat /proc/bus/input/devices
```

Verify the touch controller appears with VID `0484` / PID `5750`.

### Auto-blank

`BLANK_TIMEOUT` in `touch-bridge.py` controls how many seconds of inactivity trigger HDMI off. Default is `0` (disabled). To change:

```sh
# Enable 24-hour auto-blank:
sed -i 's/BLANK_TIMEOUT = .*/BLANK_TIMEOUT = 24 * 3600/' /data/touch-bridge.py

# Disable:
sed -i 's/BLANK_TIMEOUT = .*/BLANK_TIMEOUT = 0/' /data/touch-bridge.py
```

Any touch wakes the display immediately.

### Bridge log

```sh
tail -f /var/log/touch-bridge.log
```

---

## How the touch bridge works

The QDtech MPI5006 uses a Windows 7 multitouch HID protocol with 3 finger slots. The HID report structure (Report ID `0x01`) is:

| Bytes | Content |
|-------|---------|
| 0 | Report ID (`0x01`) |
| 1 | Tip Switch (bit 0) + padding |
| 2 | Contact ID |
| 3–4 | X coordinate (little-endian uint16, 0–800) |
| 5–6 | Y coordinate (little-endian uint16, 0–480) |
| 7–10 | Width / Height |
| 11–20 | Finger 2 (same structure) |
| 21–30 | Finger 3 (same structure) |

The `hid-generic` driver only exposes `ABS_X`/`ABS_Y` from Finger 3 (the last slot), which is never active and always holds the maximum value. The bridge reads Finger 1 directly from the raw HID report.

---

## How the sleep button works

`venus-gui-v2`'s `ScreenBlanker` singleton reads the path from `/etc/venus/blank_display_device` at startup and just writes `1`/`0` into whatever file that points at; the button is visible only when the path is non-empty.

`blank-display-device`'s postinst redirects that path at `/etc/venus/blank_display_device.value` (a plain shadow file) and runs a daemon that reacts to writes there. On Cerbo GX the daemon uses `/sys/class/drm/card0-HDMI-A-1/status` (`echo off` / `echo on`) — the only writable file on that connector under `imx-drm` (DPMS is read-only and `force` doesn't exist).

The daemon's key trick is that after blanking it stops listening to the value file and only wakes on `inotifywait -e access` on the touchscreen device — so the GUI's eventual `setDisplayOn` writes are ignored and the display stays off until you actually touch the screen.

---

## License

MIT
