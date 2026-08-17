@echo off
setlocal
set "VIVADO=D:\2025.1\Vivado\bin\vivado.bat"
set "ROOT=%~dp0"
set "XPR=%ROOT%build\vivado\vc707_image_demo\DMA_IOMMU_PicoRV32_VC707_Image_Demo.xpr"

if not exist "%XPR%" (
  echo Creating the VC707 image demo project...
  call "%VIVADO%" -mode batch -source "%ROOT%scripts\create_vc707_image_demo_project.tcl"
  if errorlevel 1 exit /b %errorlevel%
)

call "%VIVADO%" "%XPR%"
