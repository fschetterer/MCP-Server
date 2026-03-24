@echo off
setlocal

:: ── Parameters (all required) ────────────────────────────────────────────────
:: %1 RTL version: 23 = Delphi 12 Athens  |  37 = Delphi 13 Florence
:: %2 CONFIG:      Debug, Release, NoCodeSite, _NoCodeSite, etc.
:: %3 PLATFORM:    Win32, Win64
:: %4 SKIPCLEAN:   any value = skip clean (incremental build)
:: %5 SHOWWARNINGS: any value = show warnings on console
set RTL=%1
set CONFIG=%2
set PLATFORM=%3
set SKIPCLEAN=%4
set SHOWWARNINGS=%5

if "%RTL%"=="" (echo Usage: ~Build.cmd RTL CONFIG PLATFORM [SKIPCLEAN] [SHOWWARNINGS] & exit /b 1)
if "%CONFIG%"=="" (echo Usage: ~Build.cmd RTL CONFIG PLATFORM [SKIPCLEAN] [SHOWWARNINGS] & exit /b 1)
if "%PLATFORM%"=="" (echo Usage: ~Build.cmd RTL CONFIG PLATFORM [SKIPCLEAN] [SHOWWARNINGS] & exit /b 1)

:: ── rsvars ────────────────────────────────────────────────────────────────────
:: Save CONFIG/PLATFORM — rsvars.bat overwrites them
set _CONFIG=%CONFIG%
set _PLATFORM=%PLATFORM%
call "C:\Program Files (x86)\Embarcadero\Studio\%RTL%.0\bin\rsvars.bat"
if errorlevel 1 (echo rsvars.bat not found for RTL %RTL% & exit /b 1)
set CONFIG=%_CONFIG%
set PLATFORM=%_PLATFORM%

:: ── Console output ────────────────────────────────────────────────────────────
:: Default: quiet — errors only. Keeps delphi_build MCP tool response lean
:: for AI agent context window; full verbosity goes to the log file.
set CONSOLE=/nologo /v:q /clp:NoSummary;ErrorsOnly
if not "%SHOWWARNINGS%"=="" set CONSOLE=/nologo /v:m /clp:NoSummary

:: ── File log (always full verbosity) ─────────────────────────────────────────
if not exist "%~dp0logs" mkdir "%~dp0logs"
set LOGTO=/fl /flp:logfile=%~dp0logs\MCPServer.log;verbosity=normal

:: ── Clean + Build (or Build-only if SKIPCLEAN) ───────────────────────────────
if "%SKIPCLEAN%"=="" (
    msbuild "%~dp0MCPServer.dproj" /nologo /v:q /t:clean
    if errorlevel 1 (echo Clean failed & exit /b 1)
)
msbuild "%~dp0MCPServer.dproj" %CONSOLE% %LOGTO% /p:Config=%CONFIG% /p:Platform=%PLATFORM% /t:Build
exit /b %errorlevel%
