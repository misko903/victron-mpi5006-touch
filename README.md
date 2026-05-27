# QDtech MPI5006 Touch Fix for Victron Cerbo GX (Venus OS)

> ### ⚡ Quick Install via SetupHelper Package Manager
>
> In the SetupHelper Package Manager, choose **Add Package** and enter:
>
> | Field | Value |
> |-------|-------|
> | **GitHub user** | `misko903` |
> | **Package (repository)** | `victron-mpi5006-touch` |
> | **Branch** | `setuphelper` |
>
> Then select the package from the list and choose **Install**.

---

Fixes touch input for the **QDtech MPI5001 / MPI5006** 5-inch HDMI touchscreen on a **Victron Cerbo GX** running Venus OS with the Qt6-based GUI (venus-gui-v2).

This branch packages the fix as a proper **[SetupHelper](https://github.com/kwindrem/SetupHelper)** package — clean install/uninstall via the SetupHelper package manager, runit service with auto-restart, no `rc.local` hacks.

Originally developed for a **Fiat Ducato camper van build** with the Cerbo GX mounted as a permanent panel display.

> **Manual install (no SetupHelper)?** Switch to the [`main`](https://github.com/misko903/victron-mpi5006-touch/tree/main) branch.

---

## Problem

The display image works over HDMI, but touch does not respond — or every touch appears stuck at the bottom-right corner of the screen.

**Root cause:** The `hid-generic` kernel driver maps `ABS_X`/`ABS_Y` from the last finger slot in the HID descriptor (Finger 3), which is always inactive and always reports the maximum coordinates (800, 480).

**Solution:** `touch-bridge.py` locates the device dynamically by USB VID:PID (`0484:5750`), grabs its event node exclusively, reads raw HID reports, parses Finger 1's correct X/Y coordinates, and forwards them through a uinput virtual touchscreen named "MPI5001 Touch Bridge".

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

## Installation (SetupHelper)

### Prerequisites

[SetupHelper](https://github.com/kwindrem/SetupHelper) must be installed on your Cerbo GX. If it isn't, follow the SetupHelper README first.

### 1. Clone the package

SSH into your Cerbo GX and clone this branch into `/data/`:

```sh
ssh root@<cerbo-ip>
cd /data
git clone -b setuphelper https://github.com/misko903/victron-mpi5006-touch.git
```

### 2. Install via SetupHelper

```sh
/data/SetupHelper/setup
```

Select **MpiTouchBridge** from the package list and choose **Install**.

Alternatively, run the setup script directly:

```sh
/data/victron-mpi5006-touch/setup
```

### 3. Reboot (optional)

The service starts immediately after install. A reboot is not required, but recommended to verify it survives boot.

---

## Service management

```sh
# Status
svstat /service/MpiTouchBridge

# Stop
svc -d /service/MpiTouchBridge

# Start
svc -u /service/MpiTouchBridge

# Restart
svc -t /service/MpiTouchBridge
```

Log (daemontools multilog format):
```sh
tail -n 20 /var/log/MpiTouchBridge/current
```

---

## Configuration

Edit `/data/victron-mpi5006-touch/touch-bridge.py` and restart the service:

| Constant | Default | Description |
|----------|---------|-------------|
| `ROTATION` | `0` | Touch rotation: `0` = normal, `180` = upside-down |
| `BLANK_TIMEOUT` | `0` | Seconds of inactivity before HDMI off; `0` = disabled |

Example — enable 24-hour auto-blank:
```sh
sed -i 's/BLANK_TIMEOUT = 0/BLANK_TIMEOUT = 24 * 3600/' /data/victron-mpi5006-touch/touch-bridge.py
svc -t /service/MpiTouchBridge
```

---

## Uninstall

```sh
/data/victron-mpi5006-touch/setup
```

Select **Uninstall**. The service is stopped and removed. `/data/victron-mpi5006-touch/` can then be deleted manually.

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

The `hid-generic` driver only exposes `ABS_X`/`ABS_Y` from Finger 3 (the last slot), which is never active and always holds the maximum value. The bridge reads Finger 1 directly from the raw HID report.

---

## License

MIT
