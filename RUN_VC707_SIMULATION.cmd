@echo off
setlocal
set "ROOT=%~dp0"
call "%ROOT%scripts\select_vivado.cmd"
if errorlevel 1 exit /b %errorlevel%

rem The self-checking RTL regression uses the default fast simulation image.
call "%ROOT%firmware\build_firmware.cmd"
if errorlevel 1 exit /b %errorlevel%

call "%VIVADO%" -mode batch -nolog -nojournal -notrace ^
    -source "%ROOT%scripts\run_vc707_simulation.tcl"
exit /b %errorlevel%
