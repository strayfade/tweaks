@echo off
setlocal EnableExtensions

where wsl >nul 2>&1
if errorlevel 1 (
  echo [Settings26] WSL is not available in PATH.
  exit /b 1
)

set "WIN_DIR=%~dp0."
set "WSL_DIR="
for /f "delims=" %%i in ('wsl wslpath -a "%WIN_DIR%" 2^>nul') do set "WSL_DIR=%%i"
if not defined WSL_DIR (
  echo [Settings26] Failed to resolve WSL path.
  exit /b 1
)

echo [Settings26] Building via WSL...
wsl bash -lc "cd \"$WSL_DIR\" && sed -i 's/\r$//' build.sh build-and-upload.sh ../theos-package-local.sh && chmod +x build.sh build-and-upload.sh ../theos-package-local.sh && bash ./build.sh"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
  echo [Settings26] Build failed with exit code %EXIT_CODE%.
  exit /b %EXIT_CODE%
)

echo [Settings26] Done.
exit /b 0
