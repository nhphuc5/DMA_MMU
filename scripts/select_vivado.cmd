@echo off
rem Select the newest supported Vivado installation unless VIVADO is supplied.
if defined VIVADO if exist "%VIVADO%" exit /b 0

call :try "D:\2026.1\Vivado\bin\vivado.bat"
call :try "C:\AMD\Vivado\2026.1\bin\vivado.bat"
call :try "C:\Xilinx\Vivado\2026.1\bin\vivado.bat"
call :try "D:\2025.2\Vivado\bin\vivado.bat"
call :try "C:\AMD\Vivado\2025.2\bin\vivado.bat"
call :try "C:\Xilinx\Vivado\2025.2\bin\vivado.bat"
call :try "D:\2025.1\Vivado\bin\vivado.bat"
call :try "C:\AMD\Vivado\2025.1\bin\vivado.bat"
call :try "C:\Xilinx\Vivado\2025.1\bin\vivado.bat"

if defined VIVADO (
    echo Using Vivado: %VIVADO%
    exit /b 0
)

echo ERROR: No supported Vivado installation was found.
echo Set VIVADO to the full path of vivado.bat and run again.
exit /b 1

:try
if not defined VIVADO if exist "%~1" set "VIVADO=%~1"
exit /b 0
