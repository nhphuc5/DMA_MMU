@echo off
set "OPEN_SCRIPT=C:\rtl\rtl\Project_Vivado\scripts\open_unified_project.tcl"
if not exist "%OPEN_SCRIPT%" (
    echo ERROR: Script not found: %OPEN_SCRIPT%
    pause
    exit /b 1
)
start "" "D:\2025.1\Vivado\bin\vivado.bat" -source "%OPEN_SCRIPT%"
