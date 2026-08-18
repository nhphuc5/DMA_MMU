@echo off
setlocal
set "ROOT=%~dp0"

set "UNIFIED_FW=%ROOT%firmware\prebuilt\vc707_unified\soc_uart_image_batch.hex"
if not exist "%UNIFIED_FW%" (
    echo ERROR: tracked RV32I firmware image is missing:
    echo        %UNIFIED_FW%
    echo Run firmware\build_vc707_unified_firmware.cmd only after editing firmware.
    exit /b 1
)

call "%ROOT%scripts\select_vivado.cmd"
if errorlevel 1 exit /b %errorlevel%

set "VC707_FIRMWARE_HEX=firmware/prebuilt/vc707_unified/soc_uart_image_batch.hex"
set "VC707_REPORT_SUBDIR=vc707_unified_ddr3"
set "VC707_BIT_NAME=DMA_IOMMU_PicoRV32_VC707_Unified_DDR3.bit"
set "VC707_BRAM_ADDR_WIDTH=18"
set "VC707_UART_DIVIDER=161"
set "VC707_REQUIRE_ZERO_DSP=1"
set "VC707_DDR3_PROJECT_ROOT=%ROOT:~0,-1%"

call "%VIVADO%" -mode batch -nolog -nojournal -notrace ^
    -source "%ROOT%scripts\run_vc707_ddr3_implementation.tcl"
exit /b %errorlevel%
