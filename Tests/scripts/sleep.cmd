@echo off
rem Sleeps for the configured number of seconds (default 30).
rem ping is used instead of timeout because timeout fails when the parent
rem has redirected stdin (it tries to read keys from the console).
rem Used by E2E tests for Terminate and TimedOut paths.
setlocal
set secs=%~1
if "%secs%"=="" set secs=30
ping 127.0.0.1 -n %secs% > nul
exit /b 0
