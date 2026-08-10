#!/usr/bin/env bash
#
# restore-device.sh - reapply this repo's saved defaults to the TC001.
#
# Usage:
#   restore-device.sh            # push settings + screens.json + control.html
#   restore-device.sh --dry-run  # show what would be sent, touch nothing
#
# Why this exists: a WiFi reset (holding the two arrow buttons) or a firmware
# reflash drops the device back to stock. /api/settings values and the files in
# flash are the only state worth keeping - the /api/custom effect screens are
# RAM-resident and claude-ticker.sh's reassert_screens rebuilds them from
# screens.json within ~5min, so this script deliberately does NOT push them.
#
# Settings are POSTed one key at a time: AWTRIX 0.98 silently drops a whole
# batch if any single key is unknown, and per-key posts let us report exactly
# which ones the firmware rejected.
#
# NOTE: the native app flags (TIM/DAT/TEMP/HUM/BAT) only take effect on reboot
# on 0.98 - see CLAUDE.md. This script stores them but they stay dormant until
# the device restarts.
set -uo pipefail

[ -f "$HOME/.claude/ulanzi.conf" ] && . "$HOME/.claude/ulanzi.conf"
AWTRIX_IP="${AWTRIX_IP:-192.168.1.100}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$HERE/device-settings.json"
SCREENS="$HERE/screens.json"
CONTROL="$HERE/control.html"

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

for f in "$SETTINGS" "$SCREENS" "$CONTROL"; do
  [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
done

if [ "$DRY" -eq 0 ] && ! curl -s --max-time 5 "http://$AWTRIX_IP/api/stats" >/dev/null 2>&1; then
  echo "device not reachable at $AWTRIX_IP" >&2
  exit 1
fi

# --- settings, key by key -------------------------------------------------
failed=()
while IFS=$'\t' read -r key payload; do
  if [ "$DRY" -eq 1 ]; then
    echo "POST /api/settings $payload"
    continue
  fi
  if ! curl -s --max-time 5 -X POST "http://$AWTRIX_IP/api/settings" \
       -H 'Content-Type: application/json' -d "$payload" >/dev/null 2>&1; then
    failed+=("$key")
  fi
done < <(python3 -c '
import json, sys
for k, v in json.load(open(sys.argv[1])).items():
    print(k, json.dumps({k: v}), sep="\t")
' "$SETTINGS")

# --- files in flash -------------------------------------------------------
upload() {  # upload <local> <device-path>
  local src="$1" dest="$2"
  if [ "$DRY" -eq 1 ]; then echo "UPLOAD $src -> $dest"; return; fi
  curl -s --max-time 15 -F "data=@$src;filename=$dest" \
       "http://$AWTRIX_IP/edit" >/dev/null 2>&1 \
    || failed+=("upload:$dest")
}
upload "$SCREENS" /screens.json
upload "$CONTROL" /control.html

[ "$DRY" -eq 1 ] && exit 0

if [ "${#failed[@]}" -gt 0 ]; then
  echo "rejected by firmware: ${failed[*]}" >&2
  exit 1
fi

echo "restored. effect screens repopulate on the next claude-ticker.sh pass (~5min);"
echo "run 'rm -f ~/.claude/.screens-checked && bash ~/.claude/claude-ticker.sh' to force it now."
