@echo off
rem Play as a brand-new player: clears this PC's profile, settings and match
rem history first, so the game starts with the logo, then name, clan and portrait.
rem (On a phone: Settings > Start over does the same.)
set GODOT_DIR=C:\Users\ehsan\Downloads\Compressed\Godot_v4.7.2-stable_win64.exe
set GODOT=%GODOT_DIR%\Godot_v4.7.2-stable_win64.exe
set PROJ=%~dp0.
"%GODOT_DIR%\Godot_v4.7.2-stable_win64_console.exe" --headless --path "%PROJ%" --import >nul 2>&1
start "" "%GODOT%" --path "%PROJ%" -- --fresh
