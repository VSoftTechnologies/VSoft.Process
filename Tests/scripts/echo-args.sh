#!/bin/sh
# Echoes each argument on its own line, prefixed with arg<N>=[...]
# The square brackets make trailing whitespace / quoting differences visible.
# Used by E2E tests to verify the end-to-end command-line escaping.
i=0
for arg in "$@"; do
  i=$((i + 1))
  printf 'arg%d=[%s]\n' "$i" "$arg"
done
printf 'total=%d\n' "$i"
exit 0
