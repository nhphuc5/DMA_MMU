@echo off
setlocal

rem Build the complete VC707 UART/DMA/IOMMU/systolic/DDR3 firmware image.
set "FW_ROOT=%~dp0"
if not defined MAKE_EXE set "MAKE_EXE=D:\2025.1\Vitis\gnuwin\bin\make.exe"
if not defined PYTHON_EXE set "PYTHON_EXE=D:\2025.1\tps\win64\python-3.13.0\python.exe"
set "PYTHON_MAKE=%PYTHON_EXE:\=/%"

if not exist "%MAKE_EXE%" (
    echo ERROR: GNU Make bundled with Vitis was not found:
    echo        %MAKE_EXE%
    exit /b 1
)
if not exist "%PYTHON_EXE%" (
    echo ERROR: Python bundled with Vivado/Vitis was not found:
    echo        %PYTHON_EXE%
    exit /b 1
)

pushd "%FW_ROOT%"
"%MAKE_EXE%" PYTHON=%PYTHON_MAKE% vc707-uart-image-batch
set "BUILD_RESULT=%ERRORLEVEL%"
popd
if not "%BUILD_RESULT%"=="0" exit /b %BUILD_RESULT%

if not exist "%FW_ROOT%prebuilt\vc707_unified" mkdir "%FW_ROOT%prebuilt\vc707_unified"
copy /Y "%FW_ROOT%build\vc707_uart_image_batch\soc_uart_image_batch.hex" ^
    "%FW_ROOT%prebuilt\vc707_unified\soc_uart_image_batch.hex" >nul
if errorlevel 1 exit /b 1

echo Unified VC707 firmware is ready:
echo firmware\prebuilt\vc707_unified\soc_uart_image_batch.hex
exit /b 0
