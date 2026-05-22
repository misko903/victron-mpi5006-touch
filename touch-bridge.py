#!/usr/bin/env python3
"""
QDtech MPI5001/MPI5006 touch bridge for Victron Cerbo GX (Venus OS)

Problem:
  The hid-generic kernel driver maps ABS_X/ABS_Y from the last Finger slot
  in the HID descriptor (Finger 3), which is always inactive = always reports
  max coordinates (800, 480). This causes all touches to appear at the
  bottom-right corner of the screen.

Solution:
  1. Grab /dev/input/event2 to prevent Qt6 from receiving broken events
  2. Read raw HID reports from /dev/hidraw0
  3. Parse Finger 1's correct X/Y coordinates
  4. Forward correct events via a uinput virtual device

Usage:
  python3 touch-bridge.py

Service:
  Add to /data/rc.local (see README.md)
"""

import os
import struct
import fcntl
import time
import sys

# Detect 32-bit vs 64-bit for input_event struct
LONG_SIZE = struct.calcsize('l')
EVENT_FMT = 'llHHi' if LONG_SIZE == 4 else 'qqHHi'

# uinput ioctl codes
UI_SET_EVBIT  = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_ABSBIT = 0x40045567
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502

# EVIOCGRAB: grab device exclusively
EVIOCGRAB = 0x40044590

# Linux input event constants
EV_SYN    = 0
EV_KEY    = 1
EV_ABS    = 3
ABS_X     = 0
ABS_Y     = 1
BTN_TOUCH = 0x14a
SYN_REPORT = 0

# Touch coordinate range (from HID descriptor)
X_MAX = 800
Y_MAX = 480

# Rotation: 0 = normal, 180 = upside-down
ROTATION = 0

# HID report offsets for Finger 1 (Report ID 1)
# Byte 0: Report ID (0x01)
# Byte 1: Tip Switch (bit 0) | padding (bits 1-7)
# Byte 2: Contact ID
# Bytes 3-4: X (little-endian uint16)
# Bytes 5-6: Y (little-endian uint16)
# Bytes 7-8: Width
# Bytes 9-10: Height
# (Finger 2 starts at byte 11, Finger 3 at byte 21)
REPORT_ID     = 0x01
OFF_TIP       = 1
OFF_X         = 3
OFF_Y         = 5
REPORT_SIZE   = 64


def emit(ufd, ev_type, code, value):
    """Write a Linux input event to the uinput device."""
    t = time.time()
    sec = int(t)
    usec = int((t - sec) * 1_000_000)
    ufd.write(struct.pack(EVENT_FMT, sec, usec, ev_type, code, value))


def create_uinput(ufd):
    """Configure and create the virtual uinput touchscreen device."""
    for evbit in [EV_SYN, EV_KEY, EV_ABS]:
        fcntl.ioctl(ufd, UI_SET_EVBIT, evbit)
    fcntl.ioctl(ufd, UI_SET_KEYBIT, BTN_TOUCH)
    fcntl.ioctl(ufd, UI_SET_ABSBIT, ABS_X)
    fcntl.ioctl(ufd, UI_SET_ABSBIT, ABS_Y)

    name = b'MPI5001 Touch Bridge'.ljust(80, b'\x00')
    # struct input_id: bustype=USB, vendor, product, version
    input_id = struct.pack('HHHH', 3, 0x0484, 0x5750, 0x0200)
    ff_max = struct.pack('I', 0)

    absmax = [0] * 64
    absmax[ABS_X] = X_MAX
    absmax[ABS_Y] = Y_MAX

    udev_struct = (
        name + input_id + ff_max +
        struct.pack('64i', *absmax) +
        struct.pack('64i', *([0] * 64)) +  # absmin
        struct.pack('64i', *([0] * 64)) +  # absfuzz
        struct.pack('64i', *([0] * 64))    # absflat
    )
    ufd.write(udev_struct)
    fcntl.ioctl(ufd, UI_DEV_CREATE)


def main():
    print(f"[touch-bridge] starting (long_size={LONG_SIZE})")

    # Create virtual uinput touchscreen once — survives USB reconnects
    ufd = open('/dev/uinput', 'wb', buffering=0)
    create_uinput(ufd)
    time.sleep(1)
    print("[touch-bridge] uinput device created")

    while True:
        # Wait for the HID device to appear (initial boot or USB reconnect)
        while not os.path.exists('/dev/hidraw0'):
            time.sleep(1)
        while not os.path.exists('/dev/input/event2'):
            time.sleep(1)

        evfd = None
        hfd  = None
        try:
            # Grab the original device to prevent Qt6 from receiving broken coords
            evfd = open('/dev/input/event2', 'rb', buffering=0)
            fcntl.ioctl(evfd, EVIOCGRAB, 1)
            print("[touch-bridge] grabbed /dev/input/event2")

            # Open raw HID device
            hfd = open('/dev/hidraw0', 'rb', buffering=0)
            print("[touch-bridge] ready")

            prev_tip = 0
            while True:
                try:
                    data = hfd.read(REPORT_SIZE)
                except OSError as e:
                    print(f"[touch-bridge] device disconnected: {e}", file=sys.stderr)
                    break

                if not data or len(data) < 7:
                    continue
                if data[0] != REPORT_ID:
                    continue

                tip = data[OFF_TIP] & 0x01
                x   = struct.unpack_from('<H', data, OFF_X)[0]
                y   = struct.unpack_from('<H', data, OFF_Y)[0]

                if tip or prev_tip != tip:
                    tx = (X_MAX - x) if ROTATION == 180 else x
                    ty = (Y_MAX - y) if ROTATION == 180 else y
                    emit(ufd, EV_ABS, ABS_X, tx)
                    emit(ufd, EV_ABS, ABS_Y, ty)
                    emit(ufd, EV_KEY, BTN_TOUCH, tip)
                    emit(ufd, EV_SYN, SYN_REPORT, 0)
                    if tip:
                        print(f"[touch-bridge] touch x={tx} y={ty}")

                prev_tip = tip

        except OSError as e:
            print(f"[touch-bridge] open error: {e}", file=sys.stderr)
        finally:
            if hfd:
                try:
                    hfd.close()
                except OSError:
                    pass
            if evfd:
                try:
                    evfd.close()
                except OSError:
                    pass

        print("[touch-bridge] waiting for device to reconnect...")
        time.sleep(2)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print("[touch-bridge] stopped")
    except Exception as e:
        print(f"[touch-bridge] fatal: {e}", file=sys.stderr)
        sys.exit(1)
