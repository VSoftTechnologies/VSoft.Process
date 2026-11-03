#!/bin/sh
# Exits with the integer code passed as $1 (0 if missing).
# Used by E2E tests to verify ExitCode propagation.
if [ -z "$1" ]; then
  exit 0
fi
exit "$1"
