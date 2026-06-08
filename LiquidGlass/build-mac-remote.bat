@echo off
setlocal EnableExtensions

where wsl >nul 2>&1
if errorlevel 1 (
  echo [LiquidGlass] WSL is not available in PATH.
  echo Install WSL, then run: wsl --install
  exit /b 1
)

set "WIN_DIR=%~dp0."
set "WSL_DIR="
for /f "delims=" %%i in ('wsl wslpath -a "%WIN_DIR%" 2^>nul') do set "WSL_DIR=%%i"
if not defined WSL_DIR (
  echo [LiquidGlass] Failed to resolve WSL path.
  exit /b 1
)

echo [LiquidGlass] Remote Mac build via WSL...
wsl bash -lc "cd \"$WSL_DIR\" && sed -i 's/\r$//' build-mac-remote.sh build-mac-remote.env.example 2>/dev/null || true; chmod +x build-mac-remote.sh && exec bash ./build-mac-remote.sh %*"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo [LiquidGlass] Remote build failed with exit code %EXIT_CODE%.
  exit /b %EXIT_CODE%
)

echo [LiquidGlass] Done.
exit /b 0
