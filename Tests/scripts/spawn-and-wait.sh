#!/bin/sh
# Spawns a long-running grandchild (sleep N) so the test can observe whether
# terminating the parent kills the whole tree. Prints the grandchild PID on
# its own line so the test can parse it, then waits forever (until the
# parent is killed or the grandchild exits).
#
# Usage: spawn-and-wait.sh [grandchild-sleep-seconds] [parent-sleep-seconds]
# Defaults: 30 / 60.
grandchildSecs="${1:-30}"
parentSecs="${2:-60}"

sleep "$grandchildSecs" &
echo "PID=$!"

sleep "$parentSecs"
exit 0
