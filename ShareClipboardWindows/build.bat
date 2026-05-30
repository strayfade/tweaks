@echo off
setlocal EnableExtensions EnableDelayedExpansion

cd /d "%~dp0"
set "BUILD_DIR=build"

where cmake >nul 2>&1
if errorlevel 1 (
  echo [ShareClipboard] CMake was not found in PATH.
  exit /b 1
)

if not exist "%BUILD_DIR%" mkdir "%BUILD_DIR%"

echo [ShareClipboard] Configuring...
pushd "%BUILD_DIR%"

set "CONFIGURED=0"
for %%G in ("Visual Studio 18 2026" "Visual Studio 17 2022" "Visual Studio 16 2019") do (
  if "!CONFIGURED!"=="0" (
    if exist CMakeCache.txt del /f /q CMakeCache.txt
    if exist CMakeFiles rmdir /s /q CMakeFiles
    cmake .. -G %%G -A x64
    if not errorlevel 1 set "CONFIGURED=1"
  )
)

if "!CONFIGURED!"=="0" (
  echo [ShareClipboard] Retrying with CMake default generator...
  if exist CMakeCache.txt del /f /q CMakeCache.txt
  if exist CMakeFiles rmdir /s /q CMakeFiles
  cmake ..
  if errorlevel 1 (
    popd
    echo.
    echo [ShareClipboard] Configure failed. Install the C++ desktop workload in Visual Studio.
    exit /b 1
  )
)

echo [ShareClipboard] Building...
cmake --build . --config Release
set "EXIT_CODE=%ERRORLEVEL%"
popd

if not "%EXIT_CODE%"=="0" (
  echo [ShareClipboard] Build failed with exit code %EXIT_CODE%.
  exit /b %EXIT_CODE%
)

echo [ShareClipboard] Built: %BUILD_DIR%\Release\ShareClipboard.exe
echo [ShareClipboard] Installer: run installer\build-installer.bat
exit /b 0
