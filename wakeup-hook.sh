#!/usr/bin/env bash
# Run by sleepwatcher as ~/.wakeup just after the Mac wakes.
# Re-evaluate: turn the clock back on unless we woke inside quiet hours.
"$HOME/.claude/display-power.sh" auto >/dev/null 2>&1 || true
