#!/usr/bin/env bash
#
# display-power.sh - turn the TC001 matrix on/off, with a quiet-hours rule.
#
# Usage:
#   display-power.sh on     # force the display on
#   display-power.sh off    # force the display off  (used by the Mac sleep hook)
#   display-power.sh auto   # on, UNLESS inside quiet hours -> off
#
# There is NO device-native scheduler on AWTRIX 0.98 (no time/sleep keys in
# /api/settings), so display power is driven entirely from the Mac:
#   - claude-ticker.sh calls `auto` every 15s while the Mac is awake -> enforces
#     quiet hours and turns the screen back on in the morning.
#   - the sleepwatcher hooks call `off` on sleep and `auto` on wake -> the screen
#     follows the Mac (off while it sleeps, re-evaluated when it wakes).
# Because the ticker stops while the Mac sleeps, `off` on sleep is what actually
# darkens the panel overnight when the lid is closed; quiet hours covers the
# case where the Mac is awake across 23:00-06:00.
#
# Device writes are de-duped via ~/.claude/.power-applied so the 15s ticker does
# zero curl calls while the desired power state is unchanged.
set -uo pipefail

[ -f "$HOME/.claude/ulanzi.conf" ] && . "$HOME/.claude/ulanzi.conf"
AWTRIX_IP="${AWTRIX_IP:-192.168.1.100}"     # blank to disable
QUIET_START="${QUIET_START:-23}"            # off at/after this hour (24h local)
QUIET_END="${QUIET_END:-6}"                 # on at/after this hour
APPLIED="$HOME/.claude/.power-applied"

[ -n "$AWTRIX_IP" ] || exit 0

want="${1:-auto}"
if [ "$want" = "auto" ]; then
  h=$((10#$(date +%H)))             # 10# so 08/09 aren't parsed as octal
  if [ "$h" -ge "$QUIET_START" ] || [ "$h" -lt "$QUIET_END" ]; then
    want="off"
  else
    want="on"
  fi
fi

# de-dup: skip the device write when nothing would change
[ "$want" = "$(cat "$APPLIED" 2>/dev/null || echo)" ] && exit 0

case "$want" in
  on)  val=true  ;;
  off) val=false ;;
  *)   echo "usage: $0 on|off|auto" >&2; exit 2 ;;
esac

if curl -s --max-time 4 -X POST "http://$AWTRIX_IP/api/power" \
     -H 'Content-Type: application/json' -d "{\"power\":$val}" >/dev/null 2>&1; then
  printf '%s' "$want" > "$APPLIED"
fi
