@echo off
rem Reads every line from stdin and writes it to stdout unchanged.
rem findstr "^" is the canonical pure-cmd line-pass-through: the regex ^ matches
rem the start of every line, so each input line is emitted exactly once.
rem Used by E2E tests to verify stdin redirection via TPipeSource.FromString /
rem TPipeSource.Interactive.
findstr "^"
exit /b %ERRORLEVEL%
