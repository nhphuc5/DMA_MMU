@echo off
setlocal

rem Build the physical MIG/DDR3 self-test for the VC707 target.
set "FW_ROOT=%~dp0"
set "MAKE_EXE=D:\2025.1\Vitis\gnuwin\bin\make.exe"

if not exist "%MAKE_EXE%" (
    echo ERROR: GNU Make bundled with Vitis was not found:
    echo        %MAKE_EXE%
    exit /b 1
)

pushd "%FW_ROOT%"
"%MAKE_EXE%" vc707-ddr3-test
set "BUILD_RESULT=%ERRORLEVEL%"
popd

if not "%BUILD_RESULT%"=="0" (
    echo ERROR: VC707 DDR3 firmware build failed.
    exit /b %BUILD_RESULT%
)

if not exist "%FW_ROOT%prebuilt\vc707_ddr3" mkdir "%FW_ROOT%prebuilt\vc707_ddr3"
copy /Y "%FW_ROOT%build\vc707_ddr3\soc_ddr3_test.hex" ^
    "%FW_ROOT%prebuilt\vc707_ddr3\soc_ddr3_test.hex" >nul
if errorlevel 1 (
    echo ERROR: Could not update the tracked prebuilt DDR3 firmware image.
    exit /b 1
)

echo VC707 DDR3 firmware built and copied to firmware\prebuilt\vc707_ddr3\soc_ddr3_test.hex
exit /b 0
