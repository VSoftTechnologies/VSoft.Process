@echo off
rem Writes before-timeout, then sleeps for N seconds (default 30).
rem Used to verify output written before a timeout is delivered when the
rem timeout leaves the child running (TerminateOnTimeout = False).
setlocal
set secs=%~1
if "%secs%"=="" set secs=30
echo before-timeout
ping 127.0.0.1 -n %secs% > nul
exit /b 0
