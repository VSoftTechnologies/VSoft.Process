#!/bin/sh
# Sleeps for the configured number of seconds (default 30).
# Used by E2E tests for Terminate and TimedOut paths.
secs="${1:-30}"
sleep "$secs"
exit 0
