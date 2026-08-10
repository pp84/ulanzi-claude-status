#!/usr/bin/env bash
#
# claude-usage.sh - cache Claude Code rate-limit state for the TC001 usage screen.
#
# There is no supported way to read your limits: `claude` has no `usage`
# subcommand (/usage is interactive-only), and neither stats-cache.json nor the
# session transcripts carry quota state - transcripts have per-message token
# counts but no limit or reset fields. So this reads the same undocumented OAuth
# endpoint the /usage command itself calls, using the token Claude Code stores in
# the login Keychain.
#
# Consequences worth knowing:
#   - Undocumented endpoint. It can change shape or vanish on any Claude Code
#     update. Everything here fails soft: on any error the cache is left alone
#     and the screen shows the last known values (marked stale past CACHE_MAX_AGE).
#   - The Keychain read may prompt on first run, and again after a Claude Code
#     reinstall changes the binary's code signature. Answer "Always Allow".
#
# This is deliberately a SEPARATE script from claude-ticker.sh: it does network
# I/O and uses python3 to parse JSON, neither of which the ticker may depend on
# (see CLAUDE.md - the ticker must never acquire a dependency that could take the
# status-light watchdog down with it). The two are coupled only through the flat
# cache file below, which the ticker reads with its existing grep-based parser.
#
# Usage:
#   claude-usage.sh          # refresh if the throttle has elapsed
#   claude-usage.sh force    # refresh now, ignoring the throttle
#   claude-usage.sh probe    # print the raw API response (for debugging the map)
#   claude-usage.sh show     # print the current cache
#
set -uo pipefail

CACHE="$HOME/.claude/.usage-cache.json"
STAMP="$HOME/.claude/.usage-checked"
INTERVAL=300                                     # seconds between fetches
ENDPOINT="https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE="Claude Code-credentials"

# --- response -> flat cache ---------------------------------------------------
# The cache schema is OURS and is kept ONE level deep with no nested objects, for
# the same reason screens.json is: claude-ticker.sh parses it with grep/sed alone.
#
#   session_reset  epoch seconds when the current 5h window resets (0 = unknown)
#   session_pct    percent of the 5h window USED
#   weekly_reset   epoch seconds when the 7-day quota resets (0 = unknown)
#   weekly_pct     percent of the 7-day quota USED
#   ts             epoch of this fetch, so the ticker can detect a stale cache
#
# Storing the reset *timestamp* rather than a remaining duration is deliberate:
# the ticker recomputes hours-left on every push, so the countdown stays accurate
# between the 5-minute fetches instead of stepping in 5-minute jumps.
#
# Held in a variable (rather than inlined at the call site) so `parse` mode can
# run the exact same program over a saved response - that is how this is tested
# without spending a live fetch or touching the Keychain.
PARSE_PY='
import json, sys, time

def epoch(v):
    if v is None: return 0
    if isinstance(v, (int, float)): return int(v)
    s = str(v).strip().replace("Z", "+00:00")
    try:
        import datetime
        return int(datetime.datetime.fromisoformat(s).timestamp())
    except Exception:
        return 0

def window(obj):
    """(percent USED, reset epoch) from a limit/window object.

    Both limits[].percent and the top-level five_hour.utilization are already
    percentages (utilization 3.0 == "percent": 3), so neither is rescaled - an
    earlier fraction-scaling guess turned a real 1% week into 100%.
    """
    if not isinstance(obj, dict): return (-1, 0)
    p = obj.get("percent")
    if not isinstance(p, (int, float)): p = obj.get("utilization")
    p = int(round(float(p))) if isinstance(p, (int, float)) else -1
    return (p, epoch(obj.get("resets_at")))

try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)

# Prefer the structured `limits` array (explicit kind + integer percent); fall
# back to the older top-level windows if a future build drops it.
by_kind = {l.get("kind"): l for l in (d.get("limits") or []) if isinstance(l, dict)}
sp, sr = window(by_kind.get("session")    or d.get("five_hour"))
wp, wr = window(by_kind.get("weekly_all") or d.get("seven_day"))

if sp < 0 and wp < 0:
    sys.exit(1)          # nothing recognisable: leave the old cache in place

print(json.dumps({
    "session_reset": sr,
    "session_pct": max(sp, 0),
    "weekly_reset": wr,
    "weekly_pct": max(wp, 0),
    "ts": int(time.time()),
}, separators=(",", ":")))
'

mode="${1:-auto}"

[ "$mode" = "show" ]  && { cat "$CACHE" 2>/dev/null; exit 0; }
[ "$mode" = "parse" ] && { python3 -c "$PARSE_PY"; exit $?; }

now=$(date +%s)
if [ "$mode" = "auto" ] && [ -f "$STAMP" ]; then
  last=$(cat "$STAMP" 2>/dev/null || echo 0)
  [ $(( now - last )) -lt "$INTERVAL" ] && exit 0
fi

# Claude Code stores its OAuth credentials as a JSON blob in the login Keychain;
# the subscription token lives under .claudeAiOauth.accessToken.
tok=$(security find-generic-password -s "$KEYCHAIN_SERVICE" -w 2>/dev/null | python3 -c '
import json, sys
try:
    print((json.load(sys.stdin).get("claudeAiOauth") or {}).get("accessToken", ""))
except Exception:
    print("")
' 2>/dev/null)
if [ -z "$tok" ]; then
  [ "$mode" = "probe" ] && echo "no OAuth token in Keychain (service: $KEYCHAIN_SERVICE)" >&2
  exit 0
fi

resp=$(curl -s --max-time 5 \
  -H "Authorization: Bearer $tok" \
  -H "anthropic-beta: oauth-2025-04-20" \
  "$ENDPOINT" 2>/dev/null) || exit 0
[ -n "$resp" ] || exit 0

if [ "$mode" = "probe" ]; then
  printf '%s\n' "$resp" | python3 -m json.tool 2>/dev/null || printf '%s\n' "$resp"
  exit 0
fi

out=$(printf '%s' "$resp" | python3 -c "$PARSE_PY" 2>/dev/null) || exit 0
[ -n "$out" ] || exit 0

echo "$now" > "$STAMP"
printf '%s\n' "$out" > "$CACHE.tmp" && mv -f "$CACHE.tmp" "$CACHE"
