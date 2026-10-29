@echo off
rem boink.cmd — Windows command-line shim that forwards to boink.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0boink.ps1" %*
