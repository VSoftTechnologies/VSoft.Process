#!/bin/sh
# Writes before-timeout, then sleeps for N seconds (default 30).
# Used to verify output written before a timeout is delivered when the
# timeout leaves the child running (TerminateOnTimeout = False).
secs="${1:-30}"
printf 'before-timeout\n'
sleep "$secs"
exit 0
