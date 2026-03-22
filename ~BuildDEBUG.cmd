@echo off
call "C:\Program Files (x86)\Embarcadero\Studio\23.0\bin\rsvars.bat"
@set ProductVersion=23.0
@set CompilerV=29
@set IDEver=12.3.3
@set "BDSCOMMONDIR=D:\Embarcadero Studio\23.0"
@set "BDSBin=C:\Program Files (x86)\Embarcadero\Studio\23.0\bin"
@set PATH=%WINDIR%\System32;%PATH%
@MSBuild "%~dp0MCPServer.dproj" /t:build /v:n /p:Config=DEBUG /p:platform=Win64 /p:PostBuildEvent= /p:PreBuildEvent=
