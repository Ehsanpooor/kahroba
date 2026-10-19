@echo off
rem Build the web version and serve it on your Wi-Fi so a phone can open it.
rem Run it, then open the address it prints on your phone (same Wi-Fi).
set GODOT_DIR=C:\Users\ehsan\Downloads\Compressed\Godot_v4.7.2-stable_win64.exe
set PROJ=%~dp0.
if not exist "%PROJ%\build\web" mkdir "%PROJ%\build\web"
"%GODOT_DIR%\Godot_v4.7.2-stable_win64_console.exe" --headless --path "%PROJ%" --import >nul 2>&1
"%GODOT_DIR%\Godot_v4.7.2-stable_win64_console.exe" --headless --path "%PROJ%" --export-release "Web" "%PROJ%\build\web\index.html"
python "%PROJ%\tools\patch_web.py" "%PROJ%\build\web\index.html"
for /f "tokens=2 delims=:" %%a in ('ipconfig ^| findstr /c:"IPv4" ^| findstr /v "172.30."') do set IP=%%a
echo.
echo   Open on your phone:  http://%IP: =%:8060
echo   (Windows may ask to allow Python through the firewall: choose Allow.)
echo.
python -m http.server 8060 --bind 0.0.0.0 --directory "%PROJ%\build\web"
