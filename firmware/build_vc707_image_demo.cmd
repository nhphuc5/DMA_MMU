@echo off
setlocal
cd /d "%~dp0"
make vc707-image-demo
if errorlevel 1 exit /b %errorlevel%
echo.
echo VC707 image demo RAM file:
echo %CD%\build\vc707_image_demo\soc_image_demo_with_images.hex
