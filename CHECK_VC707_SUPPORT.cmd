@echo off
setlocal
set "ROOT=%~dp0"
call "%ROOT%scripts\select_vivado.cmd"
if errorlevel 1 exit /b %errorlevel%

call "%VIVADO%" -mode batch -nolog -nojournal -notrace ^
    -source "%ROOT%scripts\check_vc707_support.tcl"
exit /b %errorlevel%
