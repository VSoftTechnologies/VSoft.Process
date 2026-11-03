#!/bin/sh
# Prints the working directory in the form cwd=<path>.
# Used by E2E tests to verify StartInfo.WorkingDirectory takes effect.
printf 'cwd=%s\n' "$(pwd)"
exit 0
