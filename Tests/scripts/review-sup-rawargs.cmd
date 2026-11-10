@echo off
rem Prints %* and %1 exactly as received, in square brackets.
rem Only for arguments the test wrote itself: they are expanded unquoted.
rem Used by the SUP-3 review test (VSoft.Process.Tests.Review.Support).
echo all=[%*]
echo first=[%1]
exit /b 0
