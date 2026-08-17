@echo off
setlocal
cd /d "%~dp0"
make image-demo
if errorlevel 1 exit /b %errorlevel%
echo.
echo Image demo RAM file:
echo %CD%\build\image_demo\soc_image_demo_with_images.hex
