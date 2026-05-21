# QDtech MPI5006 Touch Fix for Victron Cerbo GX (Venus OS)

Fixes touch input for the **QDtech MPI5001 / MPI5006** 5-inch HDMI touchscreen on a **Victron Cerbo GX** running Venus OS with the Qt6-based GUI (venus-gui-v2).

---

## Problem

The display image works over HDMI, but touch does not respond — or all touches appear stuck at the bottom-right corner of the screen.

**Root cause:** The `hid-generic` kernel driver maps `ABS_X`/`ABS_Y` from the last finger slot in the HID descriptor (Finger 3), which is always inactive and always reports maximum coordinates (800, 480). This causes every touch event to land at the bottom-right corner regardless of where you actually touch.

---

## Solution

A Python bridge script (`touch-bridge.py`) that:

1. **Grabs** `/dev/input/event2` exclusively — prevents Qt6 from receiving the broken coordinates
2. **Reads** raw HID reports from `/dev/hidraw0`
3. **Parses** Finger 1's correct X/Y coordinates
4. **Forwards** correct events via a `uinput` virtual touchscreen device that Qt6 auto-discovers

---

## Hardware

| Component | Details |
|-----------|---------|
| Display | QDtech MPI5001 / MPI5006 (5-inch, 800×480) |
| Touch controller | USB HID, VID:PID `0484:5750` |
| System | Victron Cerbo GX, Venus OS ≥ 3.x (GUI v2 / Qt6) |
| Connection | HDMI (video) + USB (touch) |

---

## Installation

### 1. Copy the bridge script to the Cerbo GX

Connect to your Cerbo GX via SSH (root, no password by default on Venus OS):

```sh
ssh root@<cerbo-ip>
```

Copy `touch-bridge.py` to `/data/` (this partition survives firmware updates):

```sh
# From your PC (adjust IP):
scp touch-bridge.py root@<cerbo-ip>:/data/touch-bridge.py
```

Or paste the contents directly using `cat`:

```sh
cat > /data/touch-bridge.py << 'EOF'
<paste touch-bridge.py contents here>
EOF
```

### 2. Create the startup script

Create `/data/rc.local` — Venus OS runs this automatically at boot if it is executable:

```sh
cat > /data/rc.local << 'EOF'
#!/bin/sh
# Wait up to 30 seconds for the USB touch device to appear
i=0
while [ $i -lt 30 ] && [ ! -e /dev/hidraw0 ]; do
    sleep 1
    i=$((i+1))
done
python3 /data/touch-bridge.py &
EOF

chmod +x /data/rc.local
```

> **How it works:** `/etc/init.d/custom-rc-late.sh` (built into Venus OS) runs `/data/rc.local` at startup if the file is executable. The `/data/` partition persists across reboots and firmware updates.

### 3. Reboot

```sh
reboot
```

After reboot, touch should work automatically. You can verify with:

```sh
ps | grep touch-bridge
```

---

## Files

| File | Description |
|------|-------------|
| `touch-bridge.py` | Main bridge script — reads hidraw, writes uinput |
| `rc.local` | Example startup script for `/data/rc.local` |

---

## Troubleshooting

**Touch still not working after reboot**

Check if the bridge is running:
```sh
ps | grep touch-bridge
```

Check if `/data/rc.local` is executable:
```sh
ls -la /data/rc.local
```

If not executable:
```sh
chmod +x /data/rc.local
```

**Wrong device nodes**

If your system uses a different event or hidraw node, check:
```sh
ls /dev/input/
ls /dev/hidraw*
cat /proc/bus/input/devices
```

Adjust `event2` and `hidraw0` in `touch-bridge.py` accordingly.

**Venus OS firmware update**

The `/data/` partition persists across firmware updates, so `touch-bridge.py` and `rc.local` survive updates automatically.

---

## How It Works (Technical Details)

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

The `hid-generic` driver only exposes `ABS_X`/`ABS_Y` from Finger 3 (the last slot), which is never active and always holds the maximum value. This bridge reads Finger 1 directly from the raw HID report.

---

## License

MIT
