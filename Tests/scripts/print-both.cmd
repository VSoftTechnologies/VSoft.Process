@echo off
rem Writes N lines to stdout and N lines to stderr, interleaved (default 1000).
rem Used to verify one target attached to both streams receives every byte.
setlocal
set count=%~1
if "%count%"=="" set count=1000
for /l %%i in (1,1,%count%) do (
    echo out %%i: the quick brown fox jumps over the lazy dog
    echo err %%i: the quick brown fox jumps over the lazy dog 1>&2
)
exit /b 0
