@echo off
rem Builds Nikxel from this clone and starts it. Run it again any time to
rem rebuild; Check for Updates in the tray menu does the same thing for you.
setlocal
cd /d "%~dp0"

where node >nul 2>nul
if errorlevel 1 (
  echo Nikxel needs Node.js 20 or later. Install it from https://nodejs.org
  echo or run:  winget install OpenJS.NodeJS.LTS
  echo then open a new terminal and run setup.cmd again.
  pause
  exit /b 1
)
where git >nul 2>nul
if errorlevel 1 (
  echo Nikxel needs Git ^(Check for Updates pulls with it^). Install it from
  echo https://git-scm.com or run:  winget install Git.Git
  pause
  exit /b 1
)

rem A running copy keeps the old code loaded; quit it first.
powershell -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='electron.exe'\" | Where-Object { $_.CommandLine -like '*%~dp0*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>nul

echo Installing dependencies...
call npm ci --no-audit --no-fund || goto :fail
rem npm 11.16+ skips install scripts package.json's allowScripts doesn't
rem approve, and electron.exe / ffmpeg.exe come from those scripts. Run them
rem directly if they were skipped anyway (an npm that ignores the field).
if not exist "node_modules\electron\dist\electron.exe" (
  echo Downloading Electron...
  call node node_modules\electron\install.js || goto :fail
)
if not exist "node_modules\ffmpeg-static\ffmpeg.exe" (
  echo Downloading ffmpeg...
  call node node_modules\ffmpeg-static\install.js || goto :fail
)
echo Building Nikxel...
call npm run build || goto :fail

echo Starting Nikxel. It adds itself to the Start menu and to startup apps.
start "" "%~dp0node_modules\electron\dist\electron.exe" "%~dp0."
exit /b 0

:fail
echo.
echo The build failed. Copy the output above when asking for help.
pause
exit /b 1
