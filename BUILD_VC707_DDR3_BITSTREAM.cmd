@echo off
setlocal
set "ROOT=%~dp0"
call "%ROOT%scripts\select_vivado.cmd"
if errorlevel 1 exit /b %errorlevel%

if not exist "%ROOT%firmware\prebuilt\vc707_ddr3\soc_ddr3_test.hex" (
    echo ERROR: prebuilt DDR3 test firmware is missing.
    echo Run firmware\build_vc707_ddr3_firmware.cmd and copy the generated HEX first.
    exit /b 1
)

call "%VIVADO%" -mode batch -nolog -nojournal -notrace ^
    -source "%ROOT%scripts\run_vc707_ddr3_implementation.tcl"
exit /b %errorlevel%
