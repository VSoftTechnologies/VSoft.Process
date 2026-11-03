@echo off
rem Prints N deterministic lines of fixed content to stdout, where N is %1 (default 2000).
rem Each line is the form: line <N>: the quick brown fox jumps over the lazy dog 0123456789
rem That works out to ~72 bytes/line; 2000 lines produces ~144 KB - well over the
rem 64 KB pipe-read buffer used by the library, so this exercises:
rem   - C1: TStreamPipeTarget.HandleData writing exact bytes (not pointer junk)
rem   - C4: POSIX read loop using a real TBytes instead of a stack array
rem   - H7: UTF-8 stitching across read boundaries (lines are pure ASCII so no
rem     decoding hazard; the value-add here is volume + multi-read)
setlocal enabledelayedexpansion
set count=%~1
if "%count%"=="" set count=2000
for /l %%i in (1,1,%count%) do (
    echo line %%i: the quick brown fox jumps over the lazy dog 0123456789
)
exit /b 0
