@echo off
setlocal
cd /d "%~dp0"
"D:\2025.1\Vivado\bin\vivado.bat" -mode batch -source scripts\run_vc707_systolic_image_dma_simulation.tcl
if errorlevel 1 (
  echo ERROR: complete image pipeline simulation failed.
  exit /b 1
)
echo PASS: complete image pipeline simulation finished.
pause
