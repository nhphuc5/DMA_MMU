@echo off
setlocal
set "ROOT=%~dp0"
set "VIVADO=D:\2025.1\Vivado\bin\vivado.bat"
set "MAKE=D:\2025.1\Vitis\gnuwin\bin\make.exe"

if not exist "%VIVADO%" (
  echo ERROR: Vivado 2025.1 was not found at %VIVADO%
  pause
  exit /b 1
)
if not exist "%MAKE%" (
  echo ERROR: Vitis make was not found at %MAKE%
  pause
  exit /b 1
)

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
"%VIVADO%" -mode batch -source "%ROOT%scripts\run_vc707_systolic_simulation.tcl" -notrace
if errorlevel 1 (
  pause
  exit /b 1
)

echo SUCCESS: reports\systolic_soc_test.log
pause
endlocal
