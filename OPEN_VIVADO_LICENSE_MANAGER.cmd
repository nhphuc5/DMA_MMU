@echo off
setlocal
set "ROOT=%~dp0"
call "%ROOT%scripts\select_vivado.cmd"
if errorlevel 1 exit /b %errorlevel%
for %%I in ("%VIVADO%") do set "VLM=%%~dpIvlm.bat"

if not exist "%VLM%" (
    echo ERROR: Vivado License Manager was not found at:
    echo        %VLM%
    pause
    exit /b 1
)

echo Opening Vivado License Manager...
call "%VLM%"
exit /b %errorlevel%
