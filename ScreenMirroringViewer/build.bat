@echo off
setlocal

cd /d "%~dp0"

where dotnet >nul 2>&1
if errorlevel 1 (
    echo .NET 8 SDK not found. Install from https://dotnet.microsoft.com/download/dotnet/8.0
    exit /b 1
)

dotnet restore ScreenMirroringViewer.sln
if errorlevel 1 exit /b 1

dotnet build ScreenMirroringViewer.sln -c Release
if errorlevel 1 exit /b 1

echo.
echo Built: ScreenMirroringViewer\bin\Release\net8.0-windows\ScreenMirroringViewer.exe
