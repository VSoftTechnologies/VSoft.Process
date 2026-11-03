#!/bin/sh
# Starts a background grandchild that inherits (and keeps open) our stdout for
# N seconds (default 10), prints its PID (PID=<n>) and parent-done, and exits
# straight away.
# Used to verify Execute returns once PipeDrainTimeoutMS elapses instead of
# waiting for the grandchild to close the pipe.
secs="${1:-10}"
sleep "$secs" &
printf 'PID=%s\n' "$!"
printf 'parent-done\n'
exit 0
