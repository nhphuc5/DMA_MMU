@echo off
setlocal
set "ROOT=%~dp0"
set "VIVADO=D:\2025.1\Vivado\bin\vivado.bat"
set "MAKE=D:\2025.1\Vitis\gnuwin\bin\make.exe"

pushd "%ROOT%firmware"
"%MAKE%" vc707-systolic-demo
if errorlevel 1 (
  popd
  pause
  exit /b 1
)
popd

"%VIVADO%" -mode batch -source "%ROOT%scripts\create_vc707_systolic_project.tcl"
if errorlevel 1 (
  pause
  exit /b 1
)
"%VIVADO%" -mode batch -source "%ROOT%scripts\run_vc707_systolic_implementation.tcl"
if errorlevel 1 (
  pause
  exit /b 1
)
echo SUCCESS: bitstream\DMA_IOMMU_PicoRV32_VC707_Systolic.bit
pause
endlocal

