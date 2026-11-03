#!/bin/sh
# Writes one fixed line to stdout and one fixed line to stderr.
# Used by E2E tests to verify the two streams are captured separately.
printf 'this-is-stdout\n'
printf 'this-is-stderr\n' 1>&2
exit 0
