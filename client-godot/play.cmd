@echo off
rem Double-click to play. Add "demo" to watch the scripted run:  play.cmd demo
set GODOT_DIR=C:\Users\ehsan\Downloads\Compressed\Godot_v4.7.2-stable_win64.exe
set GODOT=%GODOT_DIR%\Godot_v4.7.2-stable_win64.exe
set PROJ=%~dp0.
rem pick up new or changed art / 3D models first (quick when nothing changed)
"%GODOT_DIR%\Godot_v4.7.2-stable_win64_console.exe" --headless --path "%PROJ%" --import >nul 2>&1
if /I "%1"=="demo" (
  start "" "%GODOT%" --path "%PROJ%" -- --demo
) else (
  start "" "%GODOT%" --path "%PROJ%"
)
