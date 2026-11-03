#!/bin/sh
# Writes N lines to stdout and N lines to stderr, interleaved (default 1000).
# Used to verify one target attached to both streams receives every byte.
count="${1:-1000}"
i=1
while [ "$i" -le "$count" ]; do
  printf 'out %d: the quick brown fox jumps over the lazy dog\n' "$i"
  printf 'err %d: the quick brown fox jumps over the lazy dog\n' "$i" 1>&2
  i=$((i + 1))
done
exit 0
