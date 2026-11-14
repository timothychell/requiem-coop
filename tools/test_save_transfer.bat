@echo off
setlocal
cd /d "%~dp0..\plugin"
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VSDIR=%%i
if not defined VSDIR exit /b 1
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not exist build mkdir build
cl /nologo /std:c++17 /O2 /EHsc /W4 ..\tools\test_save_transfer.cpp /Fobuild\test_save_transfer.obj /Fe:build\test_save_transfer.exe || exit /b 1
build\test_save_transfer.exe
