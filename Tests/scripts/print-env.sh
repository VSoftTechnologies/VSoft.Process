#!/bin/sh
# Prints the value of the environment variable named by $1, in the form NAME=VALUE.
# Used by E2E tests to verify TEnvironmentBuilder overrides reach the child.
if [ -z "$1" ]; then
  printf 'error=missing-variable-name\n' 1>&2
  exit 2
fi
# Indirect expansion via eval (POSIX sh lacks the ${!var} bash form).
eval "value=\${$1-}"
printf '%s=%s\n' "$1" "$value"
exit 0
