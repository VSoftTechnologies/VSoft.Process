#!/bin/sh
# Reads every line from stdin and writes it to stdout unchanged.
# Used by E2E tests to verify stdin redirection via TPipeSource.FromString /
# TPipeSource.Interactive.
cat
exit $?
