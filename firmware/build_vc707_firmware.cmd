@echo off
setlocal

rem Build the PicoRV32 firmware variant used by the VC707 hardware target.
set "FW_ROOT=%~dp0"
set "MAKE_EXE=D:\2025.1\Vitis\gnuwin\bin\make.exe"

if not exist "%MAKE_EXE%" (
    echo ERROR: GNU Make bundled with Vitis was not found:
    echo        %MAKE_EXE%
    exit /b 1
)

pushd "%FW_ROOT%"
"%MAKE_EXE%" vc707
set "BUILD_RESULT=%ERRORLEVEL%"
popd

if not "%BUILD_RESULT%"=="0" (
    echo ERROR: VC707 firmware build failed.
    exit /b %BUILD_RESULT%
)

echo VC707 firmware created at firmware\build\vc707\soc_demo.hex
exit /b 0
