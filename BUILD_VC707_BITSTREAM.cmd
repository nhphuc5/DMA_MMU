@echo off
setlocal
set "ROOT=%~dp0"
call "%ROOT%scripts\select_vivado.cmd"
if errorlevel 1 exit /b %errorlevel%

call "%ROOT%firmware\build_vc707_firmware.cmd"
if errorlevel 1 exit /b %errorlevel%

call "%VIVADO%" -mode batch -nolog -nojournal -notrace ^
    -source "%ROOT%scripts\run_vc707_implementation.tcl"
set "BUILD_RC=%errorlevel%"

if not "%BUILD_RC%"=="0" (
    set "SYNTH_LOG=%ROOT%build\vivado\vc707\DMA_IOMMU_PicoRV32_VC707.runs\synth_1\runme.log"
    if exist "%SYNTH_LOG%" (
        findstr /C:"Common 17-345" "%SYNTH_LOG%" >nul
        if not errorlevel 1 (
            echo.
            echo ============================================================
            echo VC707 RTL BUILD DID NOT FAIL BECAUSE OF HDL SOURCE CODE.
            echo Vivado cannot obtain a Synthesis license for XC7VX485T.
            echo Run OPEN_VIVADO_LICENSE_MANAGER.cmd and install a license
            echo that covers Virtex-7 XC7VX485T, then run this file again.
            echo Alternative: use Vivado 2026.1 BASIC, which officially
            echo supports all 7-Series devices, including Virtex-7.
            echo ============================================================
        )
    )
)

exit /b %BUILD_RC%
