@echo off
rem Starts a background grandchild that inherits (and keeps open) our stdout for
rem N seconds (default 10), prints parent-done and exits straight away.
rem Used to verify Execute returns once PipeDrainTimeoutMS elapses instead of
rem waiting for the grandchild to close the pipe.
setlocal
set secs=%~1
if "%secs%"=="" set secs=10
start "" /b ping -n %secs% 127.0.0.1
echo parent-done
exit /b 0
