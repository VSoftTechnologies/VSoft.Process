@echo off
rem Writes invalid-utf8.bin as is: "ab", the byte FF (never valid in UTF-8),
rem "cd", CRLF, "next", CRLF. Used to verify invalid bytes decode to U+FFFD.
type "%~dp0invalid-utf8.bin"
exit /b 0
