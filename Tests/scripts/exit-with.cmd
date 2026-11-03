@echo off
rem Exits with the integer code passed as %1 (0 if missing).
rem Used by E2E tests to verify ExitCode propagation.
if "%~1"=="" exit /b 0
exit /b %~1
