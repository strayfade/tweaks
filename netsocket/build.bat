@echo off
setlocal EnableExtensions

where wsl >nul 2>&1
if errorlevel 1 (
  echo [netsocket] WSL is not available in PATH.
  exit /b 1
)

set "WIN_DIR=%~dp0."
set "WSL_DIR="
for /f "delims=" %%i in ('wsl wslpath -a "%WIN_DIR%" 2^>nul') do set "WSL_DIR=%%i"
if not defined WSL_DIR (
  echo [netsocket] Failed to resolve WSL path.
  exit /b 1
)

echo [netsocket] Building via WSL...
wsl bash -lc "cd \"$WSL_DIR\" && sed -i 's/\r$//' build.sh build-and-upload.sh ../theos-package-local.sh && chmod +x build.sh build-and-upload.sh ../theos-package-local.sh && bash ./build.sh"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo [netsocket] Build failed with exit code %EXIT_CODE%.
  exit /b %EXIT_CODE%
)

echo [netsocket] Done.
exit /b 0
