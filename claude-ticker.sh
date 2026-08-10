#!/usr/bin/env bash
#
# claude-ticker.sh - launchd watchdog for the TC001 status light.
#
# Runs on a short launchd timer, independent of any Claude session. Its only
# job is to re-evaluate session state and re-apply the aggregate colour:
#
#   - Claude Code fires NO hook on Escape and Stop does not fire on interrupt,
#     so a held WORKING (orange) would otherwise hang forever. status-light.sh
#     ignores an orange whose heartbeat has gone stale, but something has to
#     re-run the evaluation after work stops - that's this tick.
#
# It changes no session state; status-light.sh only writes to the device when
# the aggregate colour actually changes, so most ticks are cheap no-ops.
#
# (A stock/quote page used to live here; removed for now - can be re-added as a
# separate concern without gating this watchdog on a network fetch.)
#
set -uo pipefail

"$HOME/.claude/status-light.sh" refresh </dev/null >/dev/null 2>&1 || true

# --- decorative effect screens (best-effort; MUST run AFTER the watchdog) -----
# API-pushed custom apps are wiped on a device reboot. The desired set lives in
# /screens.json on the device (a map of enabled-name -> AWTRIX effect, written by
# control.html's toggles and persisted in flash). Re-push any enabled screen that
# /api/loop no longer lists; a screen toggled off is simply absent from the file,
# so it is never re-added. Fully fire-and-forget: short timeouts and a throttle
# stamp so a flaky/absent device never slows or gates the watchdog above (the
# cardinal rule for this ticker - see the quote-page gotcha).
[ -f "$HOME/.claude/ulanzi.conf" ] && . "$HOME/.claude/ulanzi.conf"
AWTRIX_IP="${AWTRIX_IP:-192.168.1.100}"

# Per-screen settings live in the same /screens.json entry as the effect, so the
# config for a screen travels with its on/off state. Two accepted forms:
#   "matrix": "Matrix"                                   (legacy: effect only)
#   "matrix": {"effect":"Matrix","duration":8,"speed":2}  (current)
# Recognised keys: effect, duration (seconds on screen), speed (effectSettings
# .speed - how fast the effect animates), target (countdown only, YYYY-MM-DD).
#
# The schema is deliberately kept ONE level deep and free of nested objects: that
# is what lets the parser below stay pure bash/grep. This ticker runs from launchd
# every 15s and must never acquire a dependency (jq, python3) that could be absent
# and silently kill the watchdog. If you ever need a nested value here, flatten it
# to a top-level key instead - as `speed` is, rather than an `effectSettings` object.
DEFAULT_DURATION=8

# json_field <object> <key> - value of "key" from a flat JSON object, else empty.
json_field() {
  printf '%s' "$1" \
    | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*(\"[^\"]*\"|-?[0-9]+(\.[0-9]+)?|true|false)" \
    | head -n1 | sed -E "s/^\"$2\"[[:space:]]*:[[:space:]]*//; s/^\"//; s/\"$//"
}

# "countdown" is a managed screen like matrix/pong, but its text changes daily
# (days remaining until its target date), so it can't use the generic
# name->effect push below. It's special-cased by name in reassert_screens:
# pushed unconditionally on every throttled tick (not just when missing from
# the loop) so the day count actually advances.
COUNTDOWN_TARGET="2027-01-01"      # fallback when the entry has no "target"
push_countdown() {                 # push_countdown <target> <duration>
  local target="${1:-$COUNTDOWN_TARGET}" dur="${2:-$DEFAULT_DURATION}" epoch days text effect data
  epoch=$(date -j -f "%Y-%m-%d" "$target" +%s 2>/dev/null) || return 0
  days=$(( (epoch - now + 86399) / 86400 ))
  effect=""
  if   [ "$days" -gt 1 ]; then text="$days DAYS TO GO"
  elif [ "$days" -eq 1 ]; then text="1 DAY LEFT!"
  else text="IT'S HERE!"; effect="Fireworks"
  fi
  if [ -n "$effect" ]; then
    data="{\"text\":\"$text\",\"rainbow\":true,\"duration\":$dur,\"effect\":\"$effect\"}"
  else
    data="{\"text\":\"$text\",\"rainbow\":true,\"duration\":$dur,\"scrollSpeed\":75}"
  fi
  curl -s --max-time 3 -X POST "http://$AWTRIX_IP/api/custom?name=countdown" \
    -H 'Content-Type: application/json' \
    -d "$data" >/dev/null 2>&1 || true
}

# "usage" is the other non-effect managed screen (see countdown above): it shows
# time left in the current 5h window and percent left of the weekly quota, so its
# text also has to be recomputed on every tick rather than pushed once.
#
# The numbers come from ~/.claude/.usage-cache.json, written by claude-usage.sh.
# This side only ever READS that flat cache with json_field - the network call,
# the Keychain read and the JSON parsing all live in claude-usage.sh, so nothing
# here can acquire a python3/network dependency and take the watchdog down.
USAGE_CACHE="$HOME/.claude/.usage-cache.json"
USAGE_MAX_AGE=1800                 # cache older than this is shown greyed out

usage_color() {                    # usage_color <percent-remaining>
  if   [ "$1" -le 10 ]; then printf '#FF3B30'
  elif [ "$1" -le 25 ]; then printf '#FF9500'
  else                       printf '#34C759'
  fi
}

push_usage() {                     # push_usage <duration>
  local dur="${1:-$DEFAULT_DURATION}" raw sreset spct wpct ts nowsec left h m
  local sleft wleft sc wc data v
  [ -r "$USAGE_CACHE" ] || return 0
  raw=$(cat "$USAGE_CACHE" 2>/dev/null) || return 0
  sreset=$(json_field "$raw" session_reset)
  spct=$(json_field "$raw" session_pct)
  wpct=$(json_field "$raw" weekly_pct)
  ts=$(json_field "$raw" ts)
  # A half-written or schema-changed cache must not render as garbage on the
  # clock; anything non-numeric just leaves the previous app in place.
  for v in "$sreset" "$spct" "$wpct" "$ts"; do
    case "$v" in ''|*[!0-9]*) return 0 ;; esac
  done

  nowsec=$(date +%s)
  left=$(( sreset - nowsec )); [ "$left" -lt 0 ] && left=0
  h=$(( left / 3600 )); m=$(( (left % 3600) / 60 ))
  sleft=$(( 100 - spct )); wleft=$(( 100 - wpct ))
  sc=$(usage_color "$sleft"); wc=$(usage_color "$wleft")
  # A cache that stopped refreshing (expired token, endpoint moved) would
  # otherwise show a confidently wrong countdown, so grey it rather than lie.
  if [ "$ts" -gt 0 ] && [ $(( nowsec - ts )) -gt "$USAGE_MAX_AGE" ]; then
    sc='#6B7280'; wc='#6B7280'
  fi
  # Two colour fragments: time left in the 5h window, then weekly percent left,
  # each shaded by how much of ITS OWN budget remains.
  data=$(printf '{"text":[{"t":"%dH%02d ","c":"%s"},{"t":"%d%%","c":"%s"}],"duration":%s,"scrollSpeed":75}' \
           "$h" "$m" "$sc" "$wleft" "$wc" "$dur")
  curl -s --max-time 3 -X POST "http://$AWTRIX_IP/api/custom?name=usage" \
    -H 'Content-Type: application/json' \
    -d "$data" >/dev/null 2>&1 || true
}

reassert_screens() {
  local stamp="$HOME/.claude/.screens-checked" now last loop cfg name effect
  now=$(date +%s)
  if [ -f "$stamp" ]; then
    last=$(cat "$stamp" 2>/dev/null || echo 0)
    [ $(( now - last )) -lt 300 ] && return 0   # throttle to once per ~5 min
  fi
  loop=$(curl -s --max-time 3 "http://$AWTRIX_IP/api/loop") || return 0
  [ -z "$loop" ] && return 0                     # device unreachable: retry next tick
  echo "$now" > "$stamp"
  cfg=$(curl -s --max-time 3 "http://$AWTRIX_IP/screens.json")
  case "$cfg" in
    *'{'*) : ;;                                  # looks like our config: use it
    *) cfg='{"matrix":"Matrix","pong":"PingPong","brick":"BrickBreaker","radar":"Radar","checker":"Checkerboard","fireworks":"Fireworks","plasmacloud":"PlasmaCloud","ripple":"Ripple","snake":"Snake","pacifica":"Pacifica","chase":"TheaterChase","plasma":"Plasma","swirlin":"SwirlIn","swirlout":"SwirlOut","eyes":"LookingEyes","stars":"TwinklingStars","waves":"ColorWaves","countdown":"Countdown","usage":"ClaudeUsage"}' ;;  # missing/404: sane default (full effect set)
  esac
  # Split the config into one "name": <value> entry per line, where <value> is
  # either a bare "Effect" string (legacy) or a flat {...} object. The [^{}]*
  # in the object branch is what requires the no-nested-objects rule above.
  local entry val dur speed target
  while read -r entry; do
    [ -n "$entry" ] || continue
    name=$(printf '%s' "$entry" | sed -E 's/^"([^"]+)".*/\1/')
    val=$(printf '%s' "$entry" | sed -E 's/^"[^"]+"[[:space:]]*:[[:space:]]*//')
    case "$val" in
      '"'*) effect=$(printf '%s' "$val" | sed -E 's/^"//; s/"$//'); dur=""; speed=""; target="" ;;
      *)    effect=$(json_field "$val" effect)
            dur=$(json_field "$val" duration)
            speed=$(json_field "$val" speed)
            target=$(json_field "$val" target) ;;
    esac
    [ -n "$dur" ] || dur="$DEFAULT_DURATION"

    if [ "$name" = "countdown" ]; then
      push_countdown "$target" "$dur"
      continue
    fi
    if [ "$name" = "usage" ]; then
      push_usage "$dur"
      continue
    fi
    [ -n "$effect" ] || continue
    case "$loop" in *"\"$name\""*) continue ;; esac
    if [ -n "$speed" ]; then
      data="{\"effect\":\"$effect\",\"text\":\"\",\"duration\":$dur,\"effectSettings\":{\"speed\":$speed}}"
    else
      data="{\"effect\":\"$effect\",\"text\":\"\",\"duration\":$dur}"
    fi
    curl -s --max-time 3 -X POST "http://$AWTRIX_IP/api/custom?name=$name" \
      -H 'Content-Type: application/json' \
      -d "$data" >/dev/null 2>&1 || true
  done < <(printf '%s' "$cfg" \
            | grep -oE '"[A-Za-z0-9_]+"[[:space:]]*:[[:space:]]*(\{[^{}]*\}|"[A-Za-z0-9_]+")')
}
# Refresh the rate-limit cache before pushing screens, so the usage screen shows
# this tick's numbers rather than lagging one push behind. Self-throttled to once
# per 5 min with its own short curl timeout, and - like everything below the
# watchdog - fully best-effort: if it fails the cache simply goes stale and
# push_usage greys the screen out.
"$HOME/.claude/claude-usage.sh" >/dev/null 2>&1 || true

reassert_screens || true

# --- display power / quiet hours (best-effort; MUST run AFTER the watchdog) ----
# No device-native scheduler exists, so quiet hours (and the morning turn-on) are
# enforced here while the Mac is awake. display-power.sh de-dups its own device
# writes, so most ticks are no-ops. The Mac-sleep side is handled by the
# sleepwatcher hooks (~/.sleep -> off, ~/.wakeup -> auto), not here.
"$HOME/.claude/display-power.sh" auto >/dev/null 2>&1 || true
