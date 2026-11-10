@echo off
rem Ignores its arguments (it never expands them, so nothing in them can be
rem run by this script) and says that it ran.
rem Used by the SUP-1 review tests (VSoft.Process.Tests.Review.Support).
echo review-sup-noop ran
exit /b 0
