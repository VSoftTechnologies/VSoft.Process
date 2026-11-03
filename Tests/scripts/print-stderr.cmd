@echo off
rem Writes one fixed line to stdout and one fixed line to stderr.
rem Used by E2E tests to verify the two streams are captured separately.
echo this-is-stdout
echo this-is-stderr 1>&2
exit /b 0
