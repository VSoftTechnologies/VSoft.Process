@echo off
rem Echoes each argument on its own line, prefixed with arg<N>=[...]
rem The square brackets make trailing whitespace / quoting differences visible.
rem Used by E2E tests to verify the end-to-end command-line escaping for the M8 fix.
setlocal enabledelayedexpansion
set /a i=0
:loop
if "%~1"=="" goto :done
set /a i+=1
echo arg!i!=[%~1]
shift
goto :loop
:done
echo total=!i!
exit /b 0
