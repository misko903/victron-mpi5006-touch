#!/bin/sh
# HDMI blank watcher for Victron Cerbo GX with external HDMI display (e.g. MPI5006)
#
# venus-gui-v2's ScreenBlanker writes 1/0 to the file pointed to by
# /etc/venus/blank_display_device. On a built-in display that path is a
# backlight sysfs node and the kernel does the work. On an HDMI display
# we redirect that path to a plain shadow file (/data/screen-blank/state)
# and this daemon turns the HDMI output off/on in reaction to changes.
#
# Off methods, tried in order:
#   1. DRM connector "DPMS" property via /sys/class/drm/cardX-HDMI-A-Y/...
#      (clean DPMS off, monitor goes to standby; touch keeps working)
#   2. /sys/class/graphics/fb0/blank (FB_BLANK_POWERDOWN = 4)
#
# Run as root. Started by /data/rc.local.

set -u

STATE_FILE="/data/screen-blank/state"
LOG_PREFIX="[hdmi-blank-watcher]"

log() { echo "$LOG_PREFIX $*"; }

# Find the active HDMI DRM connector (status=connected)
find_hdmi_connector() {
    for c in /sys/class/drm/card*-HDMI-*; do
        [ -e "$c/status" ] || continue
        if [ "$(cat "$c/status" 2>/dev/null)" = "connected" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

# Find an fbdev that we can blank
find_fb() {
    for fb in /sys/class/graphics/fb0 /sys/class/graphics/fb1; do
        [ -e "$fb/blank" ] && echo "$fb" && return 0
    done
    return 1
}

display_off() {
    # Try DRM DPMS first
    if [ -n "${HDMI_CONNECTOR:-}" ] && [ -w "$HDMI_CONNECTOR/dpms" ]; then
        echo "off" > "$HDMI_CONNECTOR/dpms" 2>/dev/null && {
            log "display off via DRM DPMS ($HDMI_CONNECTOR)"
            return 0
        }
    fi
    if [ -n "${FB_DEV:-}" ]; then
        echo 4 > "$FB_DEV/blank" 2>/dev/null && {
            log "display off via fb blank ($FB_DEV)"
            return 0
        }
    fi
    log "WARNING: no method succeeded to turn display off"
    return 1
}

display_on() {
    if [ -n "${HDMI_CONNECTOR:-}" ] && [ -w "$HDMI_CONNECTOR/dpms" ]; then
        echo "on" > "$HDMI_CONNECTOR/dpms" 2>/dev/null && {
            log "display on via DRM DPMS"
            return 0
        }
    fi
    if [ -n "${FB_DEV:-}" ]; then
        echo 0 > "$FB_DEV/blank" 2>/dev/null && {
            log "display on via fb blank"
            return 0
        }
    fi
    log "WARNING: no method succeeded to turn display on"
    return 1
}

# --- bootstrap ---
mkdir -p "$(dirname "$STATE_FILE")"
[ -e "$STATE_FILE" ] || echo 0 > "$STATE_FILE"

HDMI_CONNECTOR="$(find_hdmi_connector || true)"
FB_DEV="$(find_fb || true)"
log "starting (connector=${HDMI_CONNECTOR:-none}, fb=${FB_DEV:-none})"

PREV=""
while true; do
    CUR="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
    if [ "$CUR" != "$PREV" ]; then
        case "$CUR" in
            1) display_off ;;
            0|"") display_on ;;
            *)    log "ignoring unexpected state '$CUR'" ;;
        esac
        PREV="$CUR"
    fi

    if command -v inotifywait >/dev/null 2>&1; then
        # Block until the file is modified; -qq = quiet
        inotifywait -qq -e modify,close_write "$STATE_FILE" 2>/dev/null || sleep 1
    else
        sleep 1
    fi
done
