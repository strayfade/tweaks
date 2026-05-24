@echo off
setlocal EnableExtensions

where wsl >nul 2>&1
if errorlevel 1 (
  echo WSL is required to build the apt repository locally.
  exit /b 1
)

set "WIN_DIR=%~dp0."
set "WSL_DIR="
for /f "delims=" %%i in ('wsl wslpath -a "%WIN_DIR%" 2^>nul') do set "WSL_DIR=%%i"
if not defined WSL_DIR (
  echo Failed to resolve WSL path.
  exit /b 1
)

echo Building apt repo via WSL...
wsl bash -lc "cd \"$WSL_DIR\" && sed -i 's/\r$//' scripts/*.sh && chmod +x scripts/*.sh && bash scripts/build-repo.sh"
exit /b %ERRORLEVEL%
