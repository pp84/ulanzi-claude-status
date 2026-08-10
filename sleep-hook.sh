#!/usr/bin/env bash
# Run by sleepwatcher as ~/.sleep just before the Mac sleeps.
# Darken the clock while the Mac is asleep (the ticker is frozen, so this is
# what actually turns it off when the lid closes).
"$HOME/.claude/display-power.sh" off >/dev/null 2>&1 || true
