@echo off
rem Prints the value of the environment variable named by %1, in the form NAME=VALUE.
rem Used by E2E tests to verify TEnvironmentBuilder overrides reach the child.
if "%~1"=="" (
    echo error=missing-variable-name 1>&2
    exit /b 2
)
call set value=%%%~1%%
echo %~1=%value%
exit /b 0
