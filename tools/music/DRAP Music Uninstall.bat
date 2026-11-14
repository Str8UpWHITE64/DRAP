@echo off
rem Double-click to remove DRAP custom music and get the game's own music back.
rem Your songs in the DRAP Music folder are not touched.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0DRAP-MusicBuilder.ps1" -Uninstall
