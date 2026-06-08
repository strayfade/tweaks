@echo off
setlocal EnableExtensions

where wsl >nul 2>&1
if errorlevel 1 (
  echo [LiquidGlass] WSL is not available in PATH.
  exit /b 1
)

set "WIN_DIR=%~dp0."
set "WSL_DIR="
for /f "delims=" %%i in ('wsl wslpath -a "%WIN_DIR%" 2^>nul') do set "WSL_DIR=%%i"
if not defined WSL_DIR (
  echo [LiquidGlass] Failed to resolve WSL path.
  exit /b 1
)

echo [LiquidGlass] Remote Mac build + device install via WSL...
wsl bash -lc "cd \"$WSL_DIR\" && sed -i 's/\r$//' build-mac-remote.sh build-mac-remote-and-upload.sh 2>/dev/null; chmod +x build-mac-remote.sh build-mac-remote-and-upload.sh && exec bash ./build-mac-remote-and-upload.sh %*"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo [LiquidGlass] Failed with exit code %EXIT_CODE%.
  exit /b %EXIT_CODE%
)

echo [LiquidGlass] Done.
exit /b 0
