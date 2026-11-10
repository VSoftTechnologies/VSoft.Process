#!/bin/sh
# Starts a grandchild (sleep N) that ignores SIGTERM, prints its pid as
# "PID=<n>" and then sleeps itself with the default SIGTERM action.
#
# SIGTERM is ignored in this shell before the grandchild is forked (an
# ignored disposition is inherited by fork and survives exec), so there is no
# window in which the grandchild could still die from a SIGTERM. The shell
# then takes the default action back for itself.
#
# The grandchild's stdout / stderr go to /dev/null so it does not hold the
# test's pipes open.
#
# Usage: review-posix-term-ignoring.sh [grandchild-sleep-seconds] [parent-sleep-seconds]
# Defaults: 30 / 60.
grandchildSecs="${1:-30}"
parentSecs="${2:-60}"

trap '' TERM
sleep "$grandchildSecs" >/dev/null 2>&1 &
grandchildPid=$!
trap - TERM

echo "PID=$grandchildPid"

sleep "$parentSecs"
exit 0
