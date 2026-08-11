@echo off
setlocal

set "GRADLE_VERSION=8.14"
set "GRADLE_SHA256=61ad310d3c7d3e5da131b76bbf22b5a4c0786e9d892dae8c1658d4b484de3caa"
set "CACHE_ROOT=%USERPROFILE%\.gradle\finguard-wrapper"
set "GRADLE_HOME=%CACHE_ROOT%\gradle-%GRADLE_VERSION%"
set "ARCHIVE=%CACHE_ROOT%\gradle-%GRADLE_VERSION%-bin.zip"

if not exist "%GRADLE_HOME%\bin\gradle.bat" (
  if not exist "%CACHE_ROOT%" mkdir "%CACHE_ROOT%"
  powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; if (-not (Test-Path -LiteralPath '%ARCHIVE%')) { Invoke-WebRequest -Uri 'https://services.gradle.org/distributions/gradle-%GRADLE_VERSION%-bin.zip' -OutFile '%ARCHIVE%' }; $actual=(Get-FileHash -Algorithm SHA256 -LiteralPath '%ARCHIVE%').Hash.ToLowerInvariant(); if ($actual -ne '%GRADLE_SHA256%') { Remove-Item -Force -LiteralPath '%ARCHIVE%'; throw 'Gradle distribution checksum verification failed.' }; Expand-Archive -LiteralPath '%ARCHIVE%' -DestinationPath '%CACHE_ROOT%' -Force"
  if %ERRORLEVEL% NEQ 0 exit /b %ERRORLEVEL%
)

call "%GRADLE_HOME%\bin\gradle.bat" %*
exit /b %ERRORLEVEL%
