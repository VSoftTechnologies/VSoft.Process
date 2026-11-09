@echo off
rem Writes the file named by %1 to stdout as is (type does no code-page
rem conversion), so a test controls exactly which bytes the child prints.
rem Used for UTF-8 output, which echo cannot produce reliably: chcp 65001
rem on the same cmd /c line does not change that line's echo.
type "%~1"
exit /b 0
