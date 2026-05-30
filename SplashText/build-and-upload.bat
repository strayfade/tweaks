@echo off
setlocal EnableExtensions

where wsl >nul 2>&1
if errorlevel 1 (
  echo [SplashText] WSL is not available in PATH.
  exit /b 1
)

set "WIN_DIR=%~dp0."
set "WSL_DIR="
for /f "delims=" %%i in ('wsl wslpath -a "%WIN_DIR%" 2^>nul') do set "WSL_DIR=%%i"
if not defined WSL_DIR (
  echo [SplashText] Failed to resolve WSL path.
  exit /b 1
)

echo [SplashText] Building and installing via WSL...
wsl bash -lc "cd \"$WSL_DIR\" && sed -i 's/\r$//' build.sh build-and-upload.sh ../theos-package-remote.sh ../theos-package-local.sh control && chmod +x build.sh build-and-upload.sh ../theos-package-remote.sh ../theos-package-local.sh && bash ./build-and-upload.sh"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo [SplashText] Build/install failed with exit code %EXIT_CODE%.
  exit /b %EXIT_CODE%
)

echo [SplashText] Done.
exit /b 0
