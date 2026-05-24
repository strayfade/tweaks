@echo off
setlocal EnableExtensions

set "ROOT_DIR=%~dp0"

if not "%~1"=="" goto :single

call "%ROOT_DIR%netsocket\build.bat" || exit /b %ERRORLEVEL%
call "%ROOT_DIR%SensorUsageLog\build.bat" || exit /b %ERRORLEVEL%
call "%ROOT_DIR%LSText\build.bat" || exit /b %ERRORLEVEL%
call "%ROOT_DIR%MCSplash\build.bat" || exit /b %ERRORLEVEL%
call "%ROOT_DIR%StandBy\build.bat" || exit /b %ERRORLEVEL%

echo All tweaks built and installed.
exit /b 0

:single
set "TWEAK_NAME=%~1"
if not exist "%ROOT_DIR%%TWEAK_NAME%\build.bat" (
  echo Unknown tweak "%TWEAK_NAME%".
  echo Valid options: netsocket, SensorUsageLog, LSText, MCSplash, StandBy
  exit /b 1
)

call "%ROOT_DIR%%TWEAK_NAME%\build.bat"
exit /b %ERRORLEVEL%
