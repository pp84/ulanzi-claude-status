#!/usr/bin/env bash
#
# status-light.sh - Claude Code status light for Ulanzi TC001
#
# Called by Claude Code hooks with one argument:
#   blue     -> a session is working   (UserPromptSubmit, and PostToolUse heartbeat)
#   red      -> a session needs you     (Notification: permission_prompt/elicitation_dialog)
#   green    -> a session is idle/done  (Stop, and Notification: idle_prompt)
#   end      -> a session closed        (SessionEnd)
#   refresh  -> re-evaluate only        (launchd ticker watchdog; changes no state)
#
# It tracks every live session separately and shows the single most urgent
# state across all of them: red beats blue beats green.
#
# Interrupt handling: Claude Code fires NO hook when you press Escape, and the
# Stop hook does not fire on interrupt - so a plain "blue" would hang forever.
# Instead "blue" is a heartbeat: PostToolUse re-stamps it on every tool call,
# and a stale blue (no heartbeat for WORK_STALE_SEC) is ignored. The ticker
# calls "refresh" so a stuck WORKING clears on its own shortly after work stops,
# even while you sit editing an interrupted prompt.
#
set -uo pipefail

# ============================ CONFIG ============================
# Ulanzi TC001 running AWTRIX 3. Leave empty to disable the clock.
# Put your device's address in ~/.claude/ulanzi.conf (AWTRIX_IP="192.168.x.y")
# so it survives a re-copy from the repo, or just edit the default below.
[ -f "$HOME/.claude/ulanzi.conf" ] && . "$HOME/.claude/ulanzi.conf"
AWTRIX_IP="${AWTRIX_IP:-192.168.1.100}"

# A session that goes quiet for this many minutes is treated as dead,
# so a crashed terminal can never pin the light on the wrong colour.
STALE_MIN=30

# A WORKING (blue) heartbeat older than this many seconds means the turn
# stopped (finished or interrupted) - ignore it so the clock returns. Must be
# comfortably longer than the gap between tool calls in a normal turn.
WORK_STALE_SEC=300
# ================================================================

STATE_DIR="$HOME/.claude/light-state"   # one file per session: its colour
APPLIED="$HOME/.claude/.light-applied"  # last colour pushed to the device
LOCK="$HOME/.claude/.light.lock.d"
mkdir -p "$STATE_DIR"

want="${1:-green}"

# --- which session is this, and what did the hook say? ---
# Hooks send JSON on stdin (session_id + message); refresh/CLI have none.
sid="manual"; msg=""
if [ "$want" != "refresh" ] && [ ! -t 0 ]; then
  payload=$(python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    print(d.get("session_id","manual"))
    print(d.get("message",""))
except Exception:
    print("manual"); print("")' 2>/dev/null)
  sid=$(printf '%s\n' "$payload" | sed -n '1p')
  msg=$(printf '%s\n' "$payload" | sed -n '2p')
fi
sid=$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')   # safe as a filename

# Belt-and-suspenders: even though the Notification hook is now routed by type
# (idle_prompt -> green, permission_prompt -> red) in settings.json, downgrade
# any "red" whose message is the idle text, in case an older Claude Code build
# sends every notification to the red hook.
if [ "$want" = "red" ]; then
  case "$msg" in
    *"waiting for your input"*|*"waiting for input"*) want="green" ;;
  esac
fi

# --- record this session's state (refresh changes nothing) ---
# Writing the file also bumps its mtime, which is the blue heartbeat.
if [ "$want" = "refresh" ]; then
  :
elif [ "$want" = "end" ]; then
  rm -f "$STATE_DIR/$sid"
else
  printf '%s' "$want" > "$STATE_DIR/$sid"
fi

# --- drop sessions that died without firing SessionEnd ---
find "$STATE_DIR" -type f -mmin +"$STALE_MIN" -delete 2>/dev/null || true

# --- aggregate across all live sessions: red > blue > green ---
# red is sticky (a real "needs you"); blue must be a fresh heartbeat, else a
# finished/interrupted turn would keep WORKING on screen with no hook to clear it.
now=$(date +%s)
have_red=0; have_blue=0
for f in "$STATE_DIR"/*; do
  [ -e "$f" ] || continue
  case "$(cat "$f" 2>/dev/null)" in
    red) have_red=1 ;;
    blue|orange)   # accept legacy "orange" from in-flight sessions pre-reload
      age=$(( now - $(stat -f %m "$f" 2>/dev/null || echo 0) ))
      [ "$age" -le "$WORK_STALE_SEC" ] && have_blue=1
      ;;
  esac
done
color="green"
[ "$have_blue" = 1 ] && color="blue"
[ "$have_red" = 1 ] && color="red"

# --- only touch the device when the resulting colour actually changes ---
# This is what makes the per-tool blue heartbeat cheap: it re-stamps the
# state file but skips all curl calls while the colour stays blue.
[ "$color" = "$(cat "$APPLIED" 2>/dev/null || echo)" ] && exit 0

# --- serialise device writes so two hooks never collide ---
# Portable lock (macOS has no flock): mkdir is atomic. Wait up to ~5s, then
# proceed anyway rather than drop the update; the lock is freed on exit.
for _ in $(seq 1 50); do
  mkdir "$LOCK" 2>/dev/null && { trap 'rmdir "$LOCK" 2>/dev/null' EXIT; break; }
  sleep 0.1
done

# --------------------------- AWTRIX ----------------------------
aw() { [ -z "$AWTRIX_IP" ] && return 0; curl -s -m 2 "$@" >/dev/null 2>&1 || true; }

awtrix_apply() {
  [ -z "$AWTRIX_IP" ] && return 0
  case "$1" in
    red)
      # a held notification interrupts the loop and stays until state changes.
      # stack:false so repeated reds REPLACE the current one instead of piling
      # up a queue that would need many dismisses to clear.
      aw "http://$AWTRIX_IP/api/notify" -H 'Content-Type: application/json' \
         -d '{"text":"WAITING","color":"#FF2A2A","hold":true,"stack":false,"textCase":2}'
      ;;
    blue)
      # held WORKING notification, symmetric with WAITING so it's always
      # visible (not a rotating page that any held red would mask). stack:false
      # means a later red REPLACES this one instead of queueing behind it.
      aw "http://$AWTRIX_IP/api/notify" -H 'Content-Type: application/json' \
         -d '{"text":"WORKING","color":"#2A7AFF","hold":true,"stack":false,"textCase":2}'
      ;;
    green)
      aw -X POST "http://$AWTRIX_IP/api/notify/dismiss"     # clear WORKING/WAITING
      aw "http://$AWTRIX_IP/api/custom?name=claude" -d ''   # remove legacy page; clock + ticker resume
      ;;
  esac
}

# ---------------------------- drive ----------------------------
awtrix_apply "$color"
printf '%s' "$color" > "$APPLIED"

exit 0
