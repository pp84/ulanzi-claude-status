# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A small set of shell scripts that turn an **Ulanzi TC001** pixel clock (running **AWTRIX 3** firmware) into a live status display for Claude Code sessions. No build step — these are standalone bash scripts deployed by copying them into `~/.claude/` and wiring them up via Claude Code hooks + a launchd timer.

The device is reached over the LAN via the AWTRIX HTTP API at `http://$AWTRIX_IP/api/...`. Each script resolves `AWTRIX_IP` the same way: it sources `~/.claude/ulanzi.conf` if that file exists, then falls back to a placeholder default (`192.168.1.100`) near the top of the script. **Keep the real address in `ulanzi.conf` only** — it is gitignored, so re-copying a script from the repo can never clobber it. `QUIET_START`/`QUIET_END` can be overridden the same way.

## Architecture

Two independent scripts drive the same clock, coordinating only through AWTRIX's page/notification model:

- **`status-light.sh`** — invoked by Claude Code hooks with one of `blue|red|green|end|refresh`. It is *multi-session aware*: each session's desired state is written to a file in `~/.claude/light-state/` keyed by `session_id` (read from the hook's JSON on stdin). The script then aggregates **all** live sessions and shows the single most urgent state — **red > blue > green**. This is why state lives on disk rather than in the script: any hook invocation must be able to see every other session's state. (The working state is keyed `blue` — WORKING renders blue `#2A7AFF`; the script still accepts a legacy `orange` *on read* for in-flight sessions whose hooks predate the rename.)
  - `blue` (UserPromptSubmit + **PostToolUse**) and `red` (Notification) → both **held** AWTRIX notifications (`/api/notify` with `"hold":true`, `"stack":false`) so they're always on top of the page loop and cleanly *replace* each other. Deliberately symmetric: an earlier version made the working state a rotating custom page, which any held red would completely mask, so WORKING never showed.
  - `green` (Stop + idle Notification) → dismisses the held notification (`/api/notify/dismiss`); the clock face resumes; also clears any legacy `claude`/`stock` custom page.
  - `end` (SessionEnd) → deletes that session's state file.
  - `refresh` (launchd ticker) → re-evaluates and re-applies the aggregate colour **without changing any session state**.
  - **Interrupt / heartbeat model (important):** Claude Code fires *no* hook on Escape and `Stop` does **not** fire on interrupt, so a plain held blue would hang forever. So `blue` is a **heartbeat**: `PostToolUse` re-stamps the state file on every tool call, and aggregation **ignores a blue whose mtime is older than `WORK_STALE_SEC` (45s)**. The ticker's `refresh` (every 15s) is what actually re-applies after work stops, so a WORKING left by an interrupt clears on its own within ~45–60s — even while you sit editing the interrupted prompt. `red` is *not* heartbeated (it must persist while genuinely waiting on you); it clears via green/idle or the `STALE_MIN` reaper.
  - **Progress bar on the held notifications:** WORKING and WAITING carry an AWTRIX `progress` bar (bottom row) showing **percent of the current 5-hour budget *spent*** — so the bar grows from the left as you burn through the window and goes amber at 75% / red at 90% as it fills, rather than shrinking away as a "remaining" bar would. The figure is read from `~/.claude/.usage-cache.json` with a grep-only `json_field` — never `jq`/`python3`, for the same reason the ticker avoids them — and is strictly decorative: an unreadable, non-numeric or >30min-old cache simply drops the `progress` keys and pushes the plain notification. The status light must never be degraded by the usage feature.
  - **Device-write dedup:** the per-tool heartbeat would otherwise spam the clock, so the script writes to the device **only when the aggregate colour changes** vs the last-applied value cached in `~/.claude/.light-applied`. While a turn stays blue, heartbeats do zero curl calls. Because the bar has to redraw as the budget drains, that cache key is `colour:bucket` (e.g. `blue:3`) with the bar **bucketed to 5%** — roughly one extra push per 15 min of a 5h window, driven by the ticker's `refresh`, rather than a push per percentage point which would undo the dedup. Green carries no bar, so its key stays a bare colour and idle remains a no-op.
  - **Notification routed by type, not text:** `settings.json` matches the notification *type* — `idle_prompt → green`, `permission_prompt|elicitation_dialog → red` (so AskUserQuestion dialogs show WAITING too). The script keeps a message-text downgrade of idle→green as a fallback for older Claude Code builds that don't tag types.
  - Other robustness: an atomic `mkdir` lock at `~/.claude/.light.lock.d` serialises device writes (deliberately **not** `flock` — macOS ships none); `stack:false` so repeated notifications replace rather than queue; `STALE_MIN` (30 min) reaps dead sessions.

- **`claude-ticker.sh`** — run on a 15s launchd timer, independent of any session. Its primary job is to call `status-light.sh refresh` each tick (see the interrupt model above). It changes no session state, and `status-light.sh` only writes to the device when the aggregate colour changes, so most ticks are cheap no-ops. **Gotcha to remember:** a quote-page feature (gold / Stooq) used to live here, and the `refresh` call sat *after* the quote fetch's `exit 0` guards — so whenever the market was closed or Stooq was flaky the script bailed before the watchdog ran, and WORKING hung forever. The watchdog must always run first/unconditionally.
  - **Secondary concern — decorative screen reassert (`reassert_screens`):** custom apps pushed via `/api/custom` (the `matrix`/`pong` effect screens) are wiped on a device reboot. The ticker re-pushes any *enabled* one missing from `/api/loop`, throttled to once per ~5 min via `~/.claude/.screens-checked`, with short `curl --max-time` timeouts and everything `|| true`. This is the "separate concern that never gates the watchdog" the original design anticipated: it runs strictly **after** the `refresh` line, so a flaky/absent device can never delay or block the status light. Reboot wipes self-heal within ~5 min.
    - **Per-screen config.** Each entry carries its own settings, so a screen's config travels with its on/off state. Two forms are accepted: `"matrix":"Matrix"` (legacy, effect only) and `"matrix":{"effect":"Matrix","duration":8,"speed":2}` (current). Keys: `effect`, `duration` (seconds on screen — overrides the global `ATIME`, which is only a fallback for apps that don't set one), `speed` (`effectSettings.speed`, how fast the effect animates), and `target` (countdown only, `YYYY-MM-DD`). **There is no per-screen transition speed** — `TSPEED` governs the transition *between* apps and is global to the device; AWTRIX exposes no per-app equivalent.
      - **The schema must stay one level deep, with no nested objects.** `claude-ticker.sh` parses it with `grep`/`sed` alone, whose object branch is `\{[^{}]*\}` — a nested object silently breaks it. This is deliberate: the ticker runs from launchd every 15s and must never depend on `jq`/`python3`, which could be missing and would take the status-light watchdog down with it. If a nested value is ever needed, flatten it to a top-level key, the way `speed` is flattened out of `effectSettings`.
    - **Single source of truth = `/screens.json` on the device** (persisted in flash via `/edit`, survives reboot): a flat JSON map of *enabled* screen name → config, e.g. `{"matrix":"Matrix","pong":"PingPong"}`. It is edited in exactly one place — `control.html`'s **managed toggles** (orange = on / grey = off), which write the file *and* immediately push/remove the `/api/custom` app. The effects are pushed with empty text so they fill the 32×8 matrix.
      - **`reassert_screens` reconciles `/api/loop` to that file in both directions**, and both halves matter. It re-pushes entries that are enabled but missing from the loop (the reboot-recovery case), *and* deletes screens still live in the loop that the file no longer enables. The removal half is scoped by `CATALOG` — a name list in `claude-ticker.sh` mirroring `control.html`'s `MANAGED` array, so reconciling never touches a hand-pushed custom app that the UI doesn't own. **Keep `CATALOG` and `MANAGED` in sync when adding a screen**, or the new one can be added but never removed.
      - **If `/screens.json` is missing or unreadable the ticker does nothing** — no config means no opinion. It used to fall back to "enable the entire effect catalogue", which is how the loop once ended up holding 19 apps while only 3 toggles read as on: the fallback pushed them all, and with no removal half they outlived every toggle until a reboot. Don't reintroduce a default here; a bare device is seeded by `restore-device.sh` uploading the repo's `screens.json`.
      - The repo's `screens.json` is a **snapshot** of the device file for disaster recovery, in the same sense as `device-settings.json` — not a second place to configure screens. Re-dump it after changing toggles: `curl -s "http://$AWTRIX_IP/screens.json" > screens.json`.
    - **`countdown` is a special case, not a real AWTRIX effect.** Its value in `screens.json` (`"Countdown"`) is just a sentinel — `claude-ticker.sh`'s `reassert_screens` recognizes the name `countdown` and routes it to `push_countdown` instead of the generic name→effect push, since its text has to change daily rather than just being re-added when missing. `push_countdown` computes days remaining until the entry's `target` date (set in `control.html`; `COUNTDOWN_TARGET` near the top of `claude-ticker.sh` is only a fallback for entries that lack one) and pushes `"$N DAYS TO GO"` (rainbow text) → `"1 DAY LEFT!"` → `"IT'S HERE!"` (rainbow text over a `Fireworks` background effect) on the day itself. Because it's handled inside `reassert_screens`, it's still throttled to the same ~5min cadence and still gated by the enabled/disabled check in `screens.json` — it just skips the "already in loop" short-circuit so the text actually advances daily. `control.html`'s toggle treats it like any managed screen, seeding a target 30 days out on enable; its `countdownPayload()` mirrors `push_countdown`'s text rules so a target edit shows on the panel immediately rather than waiting for the next ~5min tick. **Keep the two in sync** — they encode the same `N DAYS TO GO` / `1 DAY LEFT!` / `IT'S HERE!` thresholds in two languages.
    - **`usage` is the second pseudo-effect**, same shape as `countdown`: its `screens.json` value (`"ClaudeUsage"`) is a sentinel, `reassert_screens` routes the name to `push_usage`, and it skips the "already in loop" short-circuit so the numbers advance. It shows **time left in the current 5-hour window** and **percent of that window's budget still unspent**, as two AWTRIX colour-fragments (`{"t":…,"c":…}`) — e.g. `2H15 85%` — both shaded green/amber/red by the session budget remaining. The session budget is the number that answers "can I keep working now"; the clock alone only says when the window rolls over. **The weekly quota is deliberately not shown** (it is never close to spent in practice); dropping it also keeps the line at ~30 of the 32 columns, which is why the app sets `"noScroll":true` and sits still rather than scrolling. Re-check that width if a fragment is ever added back. `push_usage` only ever *reads* the flat cache at `~/.claude/.usage-cache.json` with the same `json_field` grep helper; a non-numeric or missing field returns without pushing, so a half-written cache can't render garbage. If the cache is older than `USAGE_MAX_AGE` (30 min) both fragments go grey rather than showing a confidently frozen countdown.

- **`claude-usage.sh`** — writes that cache; the only piece that talks to Anthropic. **There is no supported source for these numbers**: `claude` has no `usage` subcommand (`/usage` is interactive-only), `stats-cache.json` holds only daily message/tool counts, and the session transcripts carry per-message token counts but *no* limit or reset fields. So it reads the same undocumented endpoint `/usage` itself calls — `GET https://api.anthropic.com/api/oauth/usage`, bearer token from the login Keychain item `Claude Code-credentials` (`.claudeAiOauth.accessToken`), `anthropic-beta: oauth-2025-04-20`.
  - Response shape: a `limits` array of `{kind, percent, resets_at}` (`kind` = `session` / `weekly_all` / `weekly_scoped`) plus legacy top-level `five_hour` / `seven_day` objects. The parser prefers `limits` and falls back to the top-level pair. **`utilization` is already a percentage** — `3.0` means 3%, cross-checked against the array's `"percent": 3` — so it must *not* be rescaled as a fraction; doing so turns a real 1% week into 100%.
  - **Why it's a separate script from the ticker:** it does network I/O and parses JSON with `python3`, and the ticker may never take on a dependency that could be absent and kill the status-light watchdog. The two couple *only* through the flat one-level cache, which the ticker greps — same schema rule as `screens.json`, for the same reason. The ticker calls it after the watchdog, self-throttled to 5 min; every failure path leaves the old cache alone.
  - The cache stores the reset **timestamp**, not a remaining duration, so `push_usage` recomputes hours-left on every push and the countdown stays smooth between the 5-minute fetches instead of stepping in 5-minute jumps.
  - `claude-usage.sh parse` runs the exact same parser over a saved response on stdin — that's how to test a schema change without spending a live fetch or touching the Keychain. `probe` dumps the raw response, `show` prints the cache, `force` ignores the throttle.
  - Being undocumented, the endpoint can change shape or vanish on any Claude Code update; the failure mode is a stale cache and a greyed-out screen, never a wrong number. The Keychain read may prompt after a Claude Code reinstall changes the binary's code signature.
  - **`control.html` cannot mirror this one.** Unlike `countdown`, the browser has no access to the Keychain token, so enabling the toggle parks a grey `--H-- --%` placeholder and the ticker overwrites it within ~5 min. Its settings row therefore offers duration only — no effect speed, since it's text rather than an effect.

Key insight: the two scripts coordinate only through the on-disk session state in `~/.claude/light-state/`. status-light.sh (hook-driven) writes that state and pushes notifications to the device; claude-ticker.sh (launchd) periodically re-runs status-light.sh's evaluation so interrupted/finished work clears without a hook. Urgency layering is a property of AWTRIX (held notification interrupts the page loop), not of any shared code.

## control.html — runtime settings panel

The stock AWTRIX web UI (`http://<ip>/`) is **config-only** (WiFi/MQTT/Time/Icons/Files/Update/Flows) and exposes **no** brightness or app controls — those are only reachable via the `/api/settings` HTTP API, MQTT/Home Assistant, or the device buttons. `control.html` is a single self-contained page (no dependencies) that wraps that API: brightness slider + auto-brightness, app dwell time (`ATIME`), transition speed (`TSPEED`), notification dismiss, screen power, and a live `/api/stats` readout.

Deploy it onto the clock so its `/api` calls are same-origin (avoids browser CORS): `curl -F "data=@control.html;filename=/control.html" http://<ip>/edit`, then open `http://<ip>/control.html`. It uses relative `/api` paths when served from the device and falls back to the IP box when opened from disk.

**Screens card** — lists the live rotation (`/api/loop`) and manages three kinds of screen:
- **Native toggles** (Time/Date/Temp/Humidity/Battery): these map to the `/api/settings` booleans `TIM/DAT/TEMP/HUM/BAT`, but **on firmware 0.98 those flags only take effect on reboot** — setting them at runtime returns OK yet does *not* change the live loop (it's rebuilt from the flags at boot). So the toggle reflects the stored *setting* (orange = on), marks any flag that differs from the live loop with a `*`, and surfaces an **Apply changes (reboot)** button. Reboot wipes RAM-resident custom apps, so the reboot handler re-pushes the enabled effect screens afterward. (`/api/reboot` ~15s; the status light recovers via the ticker.)
- **Managed effect toggles** (matrix/pong): instant, no reboot — see `screens.json` under `claude-ticker.sh` below. Each renders as a tile with a **live 32×8 canvas preview** of its effect (`SHADERS` / `SPRITES` in the page). These are drawn procedurally — per-pixel `(x,y,t)→[r,g,b]` shaders, or small sprite routines for the ones that aren't shader-shaped (PingPong, BrickBreaker, Snake, LookingEyes, Countdown) — deliberately **not** image assets, which would bloat the device's flash. They're impressions of each effect, not pixel-exact reproductions of the firmware's rendering, so treat them as a visual index rather than a spec. One shared `requestAnimationFrame` loop drives every tile at ~12fps and idles while the tab is hidden; `collectPreviews()` must be re-called after any `innerHTML` rewrite of the toggles, since that discards the canvases.
- **Custom chips**: any other `/api/custom` app currently in the loop, each removable.

## Display power — quiet hours + follow-the-Mac

The matrix is a standalone device: powered on, it shows the clock/effects 24/7 regardless of the Mac. There is **no device-native scheduler** on AWTRIX 0.98 (no time/sleep keys in `/api/settings`, only `MATP` matrix-power), so all power automation is **Mac-driven**.

- **`display-power.sh on|off|auto`** — the single source of truth for matrix power, via `/api/power {"power":bool}`. `auto` turns the screen **off during quiet hours** (`QUIET_START=23`..`QUIET_END=6`, local time) and on otherwise. De-dups device writes via `~/.claude/.power-applied` so the 15s ticker is a no-op while the desired state is unchanged. Config (IP, quiet-hours bounds) lives at the top of the script.
- **`claude-ticker.sh`** calls `display-power.sh auto` **after** the watchdog/reassert (same cardinal rule — never gate the status light) — this enforces quiet hours and the morning turn-on, but only while the Mac is awake.
- **Follow-the-Mac (sleepwatcher):** because the ticker is frozen while the Mac sleeps, the sleep/wake transitions are handled by [`sleepwatcher`](https://formulae.brew.sh/formula/sleepwatcher) hooks: `~/.sleep` → `display-power.sh off` (darken when the lid closes), `~/.wakeup` → `display-power.sh auto` (re-evaluate on wake; stays off if woken inside quiet hours). Repo copies are **`sleep-hook.sh`** / **`wakeup-hook.sh`**; deploy them to `~/.sleep` / `~/.wakeup`. Install: `brew install sleepwatcher && brew services start sleepwatcher`.
- **Net effect:** screen is off when *(quiet hours)* **or** *(Mac asleep)*, on otherwise. Note a deliberate quirk: working late past 23:00 with the Mac awake still darkens the screen (quiet hours win), so blue WORKING won't show overnight — adjust `QUIET_START` or add a "keep on while actively working" carve-out if undesired.

## Deploy / wiring

- **`settings-hooks.json`** — the hook block to merge into `~/.claude/settings.json`. Maps `UserPromptSubmit→blue`, `Notification→red`, `Stop→green`, `SessionEnd→end`, all calling `$HOME/.claude/status-light.sh`.
- **`com.local.claude-ticker.plist`** — launchd job for the watchdog ticker (`StartInterval` 15s). Contains an absolute path to the script that must point at the real home dir. Load/reload with `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.local.claude-ticker.plist` (or the older `launchctl load`); after changing `StartInterval` you must reload for it to take effect.

The scripts run from `~/.claude/`; this repo is the source-of-truth copy. **Keep both in sync** — after editing here, copy to `~/.claude/` (and vice-versa). The `~/.claude/settings.json` hooks block must stay consistent with `settings-hooks.json`.

## Saved defaults / disaster recovery

A WiFi reset (holding the two arrow buttons) or a reflash drops the device to stock, so the known-good config is checked in here:

- **`device-settings.json`** — a verbatim snapshot of `/api/settings`. This is *state*, not code: to update it after tuning the device via `control.html`, re-dump it with `curl -s "http://$AWTRIX_IP/api/settings"` and commit the result.
- **`screens.json`** — a snapshot of the device's live enabled-screen store (see `claude-ticker.sh` above), used to seed a wiped device. The full catalog of available screens lives in `control.html`'s `MANAGED` array (and `claude-ticker.sh`'s `CATALOG`), *not* here — a screen absent from `screens.json` still appears as a toggle in the UI, just switched off. So pruning this file changes only what a restore turns on; it never removes a screen from the UI.
- **`restore-device.sh`** — reapplies all of the above (`--dry-run` to preview). Settings are POSTed **one key at a time**: 0.98 silently drops an entire batch if any single key is unknown, and per-key posts report exactly which the firmware rejected. It deliberately does *not* push `/api/custom` screens — the ticker's `reassert_screens` rebuilds those from `screens.json` within ~5 min.

One gotcha the script can't paper over: the native flags (`TIM/DAT/TEMP/HUM/BAT`) are stored but stay dormant until a reboot. A DHCP change is a one-line edit to `~/.claude/ulanzi.conf` (see above); give the device a DHCP reservation to avoid it entirely.

## Testing / operating

```bash
# Trigger a state manually (no stdin = treated as the "manual" session)
~/.claude/status-light.sh red      # show held WAITING
~/.claude/status-light.sh green    # clear back to clock + ticker

# Inspect the device ($AWTRIX_IP from ~/.claude/ulanzi.conf)
curl -s "http://$AWTRIX_IP/api/stats"                        # battery, version, current app/page
curl -s -X POST "http://$AWTRIX_IP/api/notify/dismiss"       # clear a stuck red notification

# Ticker
bash ~/.claude/claude-ticker.sh                      # run once by hand
launchctl list | grep claude-ticker                  # confirm the timer is loaded

bash -n status-light.sh                              # syntax check (no test framework)

# Usage screen
~/.claude/claude-usage.sh probe                      # raw /api/oauth/usage response
~/.claude/claude-usage.sh force && cat ~/.claude/.usage-cache.json
bash claude-usage.sh parse < saved-response.json     # test the parser, no live fetch
```

To see the usage screen rendered, note that a held blue/red notification masks the
whole page loop — dismiss it first, then `POST /api/switch {"name":"usage"}` and read
`/api/screen` back. If you dismiss by hand, also `rm ~/.claude/.light-applied` before
`status-light.sh refresh`, or the dedup cache thinks the colour is already applied and
the light stays dark.

There is no test suite; validate changes with `bash -n` and by observing the device.

The README's animated screen previews are captured from the real panel by
`tools/capture-screens.py` (polls `/api/screen`, the live 32x8 framebuffer). Re-run it
after changing an effect's settings:

```bash
python3 tools/capture-screens.py --ip "$AWTRIX_IP" --out docs/screens
```