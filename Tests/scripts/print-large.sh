#!/bin/sh
# Prints N deterministic lines of fixed content to stdout, where N is $1 (default 2000).
# Each line is the form: line <N>: the quick brown fox jumps over the lazy dog 0123456789
# That works out to ~72 bytes/line; 2000 lines produces ~144 KB - well over the
# 64 KB pipe-read buffer used by the library, so this exercises multi-read drain.
count="${1:-2000}"
i=1
while [ "$i" -le "$count" ]; do
  printf 'line %d: the quick brown fox jumps over the lazy dog 0123456789\n' "$i"
  i=$((i + 1))
done
exit 0
