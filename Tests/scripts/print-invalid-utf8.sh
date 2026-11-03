#!/bin/sh
# Writes invalid-utf8.bin as is: "ab", the byte FF (never valid in UTF-8),
# "cd", CRLF, "next", CRLF. Used to verify invalid bytes decode to U+FFFD.
cat "$(dirname "$0")/invalid-utf8.bin"
exit 0
