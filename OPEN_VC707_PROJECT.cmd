@echo off
setlocal
set "ROOT=%~dp0"
call "%ROOT%scripts\select_vivado.cmd"
if errorlevel 1 exit /b %errorlevel%

call "%ROOT%firmware\build_vc707_firmware.cmd"
if errorlevel 1 exit /b %errorlevel%

call "%VIVADO%" -source "%ROOT%scripts\open_vc707_project.tcl"
