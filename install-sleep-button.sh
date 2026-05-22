#!/bin/sh
# Install the GUI sleep button (moon/zZ on the Brief page) for a Cerbo GX
# driving an external HDMI display through the MPI5001 touch bridge.
#
# What it does:
#   1. Installs ldenisey's `blank-display-device` package, which redirects
#      /etc/venus/blank_display_device at a shadow file and runs a daemon
#      that turns the HDMI off/on via /sys/class/drm/.../status.
#   2. Patches the daemon to find the touchscreen by sysfs device name
#      (the bridge "MPI5001 Touch Bridge"), because Venus OS does not tag
#      input devices with ID_INPUT_TOUCHSCREEN=1 (the package's default
#      auto-detect can't find anything otherwise).
#   3. Installs `mod-persist` and registers `blank-display-device` so the
#      install survives Venus OS firmware updates.
#
# Run as root on the Cerbo GX. Idempotent — safe to re-run.

set -e

FEED_BASE="https://github.com/ldenisey/venus-os-configuration/raw/refs/heads/main/feed"
DAEMON_SCRIPT=/opt/victronenergy/blank-display-device/blank-display-device.sh

say() { echo "==> $*"; }

# 1. Install blank-display-device (skip if already installed)
if ! opkg list-installed 2>/dev/null | grep -q '^blank-display-device '; then
    say "installing blank-display-device"
    opkg install "$FEED_BASE/blank-display-device_1.0.0_all.ipk"
else
    say "blank-display-device already installed"
fi

# 2. Make sure the GUI's path file points at the shadow value file. The
#    package's postinst does this; if anything later restored the original
#    backlight path (e.g. a previous cleanup attempt), put it back.
say "ensuring /etc/venus/blank_display_device points at .value file"
echo "/etc/venus/blank_display_device.value" > /etc/venus/blank_display_device
[ -f /etc/venus/blank_display_device.value ] || echo 0 > /etc/venus/blank_display_device.value

# 3. Patch the daemon to find the touch-bridge by sysfs name.
say "patching daemon to look up touch-bridge via sysfs"
cat > "$DAEMON_SCRIPT" << 'PATCH'
#!/bin/sh
# Patched for the MPI5001 touch bridge: udev on Venus OS does not tag any
# input device as a touchscreen, so we discover the bridge's event device
# by sysfs name instead of `udevadm info`.

BLANK_VALUE_FILE="/etc/venus/blank_display_device.value"

find_bridge_event() {
    for syspath in /sys/class/input/event*; do
        n="$(cat "$syspath/device/name" 2>/dev/null)"
        if [ "$n" = "MPI5001 Touch Bridge" ]; then
            echo "/dev/input/$(basename "$syspath")"
            return 0
        fi
    done
    return 1
}

i=0
TOUCHSCREEN_INPUT_PATH=""
while [ $i -lt 30 ]; do
    TOUCHSCREEN_INPUT_PATH="$(find_bridge_event)"
    [ -n "$TOUCHSCREEN_INPUT_PATH" ] && [ -c "$TOUCHSCREEN_INPUT_PATH" ] && break
    sleep 1
    i=$((i+1))
done

HDMI_BLANK_FILE_PATH="/sys/class/drm/$(ls /sys/class/drm | grep -i hdmi | head -n 1)/status"

if [ ! -f "$HDMI_BLANK_FILE_PATH" ] || [ ! -c "$TOUCHSCREEN_INPUT_PATH" ]; then
    echo "Error: HDMI ($HDMI_BLANK_FILE_PATH) or touch ($TOUCHSCREEN_INPUT_PATH) not found"
    svc -d . ; exit 1
fi

echo "HDMI: $HDMI_BLANK_FILE_PATH"
echo "Touch: $TOUCHSCREEN_INPUT_PATH"

while true; do
    inotifywait -q -e modify "$BLANK_VALUE_FILE"
    value=$(cat "$BLANK_VALUE_FILE")
    if [ "$value" = "1" ]; then
        echo "Blanking screen"
        echo off > "$HDMI_BLANK_FILE_PATH"
        sleep 5
        echo "Waiting for touchscreen event"
        inotifywait -e access "$TOUCHSCREEN_INPUT_PATH"
        echo "Touch detected, unblanking screen"
        echo on > "$HDMI_BLANK_FILE_PATH"
    else
        echo "Received other value: $value"
    fi
done
PATCH
chmod +x "$DAEMON_SCRIPT"

# 4. Install mod-persist + register the package so it survives firmware updates
if ! opkg list-installed 2>/dev/null | grep -q '^mod-persist '; then
    say "installing mod-persist"
    opkg install "$FEED_BASE/mod-persist_1.1.0_all.ipk"
fi

if ! persist-opkg list 2>/dev/null | grep -q '^blank-display-device$'; then
    say "registering blank-display-device for persistence"
    persist-opkg install blank-display-device
fi

# 5. (Re)start the daemon and the GUI to pick up the new path.
say "restarting daemon and GUI"
svc -u /service/blank-display-device 2>/dev/null || true
svc -t /service/blank-display-device 2>/dev/null || true
svc -t /service/gui-v2 2>/dev/null || true

sleep 3
say "done. Daemon log:"
tail -n 10 /var/log/blank-display-device/current 2>/dev/null
say ""
say "Tap the moon icon on the Brief page to test. Any touch wakes the display."
