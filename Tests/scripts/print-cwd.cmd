@echo off
rem Prints the working directory in the form cwd=<path>.
rem Used by E2E tests to verify StartInfo.WorkingDirectory takes effect.
echo cwd=%CD%
exit /b 0
