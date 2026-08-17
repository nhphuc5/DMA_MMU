@echo off
setlocal

rem Convenience wrapper.  The Makefile is the single source of build rules.
set "FW_ROOT=%~dp0"
set "MAKE_EXE=D:\2025.1\Vitis\gnuwin\bin\make.exe"

if not exist "%MAKE_EXE%" (
    echo ERROR: GNU Make bundled with Vitis was not found:
    echo        %MAKE_EXE%
    exit /b 1
)

pushd "%FW_ROOT%"
"%MAKE_EXE%" all
set "BUILD_RESULT=%ERRORLEVEL%"
popd

if not "%BUILD_RESULT%"=="0" (
    echo ERROR: Firmware Makefile build failed.
    exit /b %BUILD_RESULT%
)

echo Firmware build completed successfully.
exit /b 0
