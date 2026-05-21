#!/bin/sh
# Install the HDMI blank shim on a Victron Cerbo GX.
#
# - Creates /data/screen-blank/state (shadow file written by venus-gui-v2)
# - Points /etc/venus/blank_display_device at that file so the GUI's
#   sleep button (moon + zZ on the Brief page) becomes functional
# - Installs /data/hdmi-blank-watcher.sh and adds it to /data/rc.local
# - Restarts the GUI so it re-reads the new blank device path
#
# Safe to re-run. Original /etc/venus/blank_display_device is backed up
# to /data/blank_display_device.orig on first run.
#
# Run as root on the Cerbo GX:
#   sh /data/install-hdmi-blank.sh

set -eu

STATE_FILE="/data/screen-blank/state"
WATCHER_SRC_NAME="hdmi-blank-watcher.sh"
WATCHER_DST="/data/$WATCHER_SRC_NAME"
BLANK_DEV_FILE="/etc/venus/blank_display_device"
BLANK_DEV_BACKUP="/data/blank_display_device.orig"
RC_LOCAL="/data/rc.local"

say() { echo "==> $*"; }

# 1. shadow state file
say "creating shadow state file $STATE_FILE"
mkdir -p "$(dirname "$STATE_FILE")"
[ -e "$STATE_FILE" ] || echo 0 > "$STATE_FILE"
chmod 666 "$STATE_FILE"

# 2. point GUI at the shadow file
if [ -e "$BLANK_DEV_FILE" ] && [ ! -e "$BLANK_DEV_BACKUP" ]; then
    say "backing up original $BLANK_DEV_FILE -> $BLANK_DEV_BACKUP"
    cp "$BLANK_DEV_FILE" "$BLANK_DEV_BACKUP"
fi
say "writing $BLANK_DEV_FILE -> $STATE_FILE"
mkdir -p "$(dirname "$BLANK_DEV_FILE")"
echo "$STATE_FILE" > "$BLANK_DEV_FILE"

# 3. install watcher script
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/$WATCHER_SRC_NAME" ] && [ "$SCRIPT_DIR/$WATCHER_SRC_NAME" != "$WATCHER_DST" ]; then
    say "installing watcher to $WATCHER_DST"
    cp "$SCRIPT_DIR/$WATCHER_SRC_NAME" "$WATCHER_DST"
fi
chmod +x "$WATCHER_DST"

# 4. wire up /data/rc.local
if [ ! -e "$RC_LOCAL" ]; then
    say "creating $RC_LOCAL"
    cat > "$RC_LOCAL" <<EOF
#!/bin/sh
# Venus OS user startup script. Anything started here survives firmware updates.
EOF
fi
if ! grep -q "$WATCHER_DST" "$RC_LOCAL"; then
    say "adding watcher launch to $RC_LOCAL"
    printf '\n# HDMI blank watcher (display sleep button)\n%s &\n' "$WATCHER_DST" >> "$RC_LOCAL"
fi
chmod +x "$RC_LOCAL"

# 5. (re)start watcher right now
say "starting watcher"
pkill -f "$WATCHER_DST" 2>/dev/null || true
"$WATCHER_DST" >/var/log/hdmi-blank-watcher.log 2>&1 &
sleep 1

# 6. restart GUI so it re-reads blank_display_device
say "restarting gui (svc -t /service/gui-v2 ...)"
if [ -d /service/gui-v2 ]; then
    svc -t /service/gui-v2
elif [ -d /service/gui ]; then
    svc -t /service/gui
else
    say "no gui service found, please reboot manually for GUI to pick up the change"
fi

say "done. After GUI restarts, tap the moon icon on the Brief page."
say "Watcher log: tail -f /var/log/hdmi-blank-watcher.log"
