@echo off
rem Spawns a long-running grandchild (powershell -> Start-Sleep) IN OUR JOB
rem so the test can observe whether terminating the parent kills the whole
rem tree. Earlier versions used `wmic process call create` which spawns via
rem the WMI service (svchost), creating a process that is NOT a descendant
rem of cmd.exe and therefore not in our Job Object - so Terminate could
rem not reach it.
rem
rem PowerShell prints its own PID (the $PID automatic variable) to stdout
rem then sleeps. Because powershell.exe is a direct child of cmd.exe (which
rem the library assigned to a JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE job),
rem killing the job kills both processes.
rem
rem Single quotes are used around the 'PID=' literal so we never need to
rem escape a double quote (cmd batch has no `\"` escape; embedding `"`
rem inside a quoted argv slot would require `""` or `^"` and is fragile).
rem
rem Usage: spawn-and-wait.cmd [grandchild-sleep-seconds]
rem Default: 60.
setlocal
set secs=%~1
if "%secs%"=="" set secs=60

powershell.exe -NoProfile -NonInteractive -Command "Write-Host ('PID=' + $PID); Start-Sleep -Seconds %secs%"
exit /b 0
