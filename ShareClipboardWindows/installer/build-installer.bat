@echo off
setlocal EnableExtensions EnableDelayedExpansion

cd /d "%~dp0"
set "ROOT=%~dp0.."
set "OUT=%~dp0output"
set "RESOURCES=%ROOT%\resources"

REM CMake/VS generators place Release output in different folders.
set "STAGE="
if exist "%ROOT%\build\Release\ShareClipboard.exe" (
  set "STAGE=%ROOT%\build\Release"
) else if exist "%ROOT%\build\x64\Release\ShareClipboard.exe" (
  set "STAGE=%ROOT%\build\x64\Release"
)

if not defined STAGE (
  echo [ShareClipboard] ShareClipboard.exe was not found.
  echo [ShareClipboard] Build the application first: ..\build.bat
  exit /b 1
)

if not exist "%RESOURCES%\icon.png" (
  echo [ShareClipboard] Missing %RESOURCES%\icon.png
  exit /b 1
)

if not exist "%STAGE%\icon.png" (
  copy /Y "%RESOURCES%\icon.png" "%STAGE%\icon.png" >nul
)

call :FindWiX
if errorlevel 1 (
  echo.
  echo [ShareClipboard] WiX Toolset was not found.
  echo [ShareClipboard] Install WiX 3.14+ and ensure candle.exe and light.exe are on PATH,
  echo [ShareClipboard] or set the WIX environment variable to the WiX install root.
  echo [ShareClipboard] Example: winget install WiXToolset.WiXToolset
  exit /b 1
)

if not exist "%OUT%" mkdir "%OUT%"

set "VERSION_DEFINE="
if defined PRODUCT_VERSION set "VERSION_DEFINE=-dProductVersion=%PRODUCT_VERSION%"

echo [ShareClipboard] Packaging from %STAGE%
echo [ShareClipboard] Compiling WiX source...

"%WIX_BIN%\candle.exe" -nologo -arch x64 ^
  -ext WixUtilExtension ^
  -dBuildOutputDir="%STAGE%" ^
  -dResourcesDir="%RESOURCES%" ^
  %VERSION_DEFINE% ^
  -out "%OUT%\\" ^
  Product.wxs
if errorlevel 1 exit /b 1

echo [ShareClipboard] Linking MSI...
"%WIX_BIN%\light.exe" -nologo ^
  -ext WixUIExtension ^
  -ext WixUtilExtension ^
  -out "%OUT%\ShareClipboardSetup.msi" ^
  "%OUT%\Product.wixobj"
if errorlevel 1 exit /b 1

echo [ShareClipboard] Built: %OUT%\ShareClipboardSetup.msi
exit /b 0

:FindWiX
if defined WIX (
  if exist "%WIX%\bin\candle.exe" (
    set "WIX_BIN=%WIX%\bin"
    exit /b 0
  )
)

where candle >nul 2>&1
if not errorlevel 1 (
  for %%I in (candle.exe) do set "WIX_BIN=%%~dpI"
  if defined WIX_BIN exit /b 0
)

for %%V in (v3.14 v3.11 v3.10) do (
  if exist "C:\Program Files (x86)\WiX Toolset %%V\bin\candle.exe" (
    set "WIX_BIN=C:\Program Files (x86)\WiX Toolset %%V\bin"
    exit /b 0
  )
)

exit /b 1
