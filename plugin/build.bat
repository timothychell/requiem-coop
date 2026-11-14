@echo off
setlocal
cd /d "%~dp0"
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set VSDIR=%%i
if not defined VSDIR (echo Visual Studio C++ build tools not found & exit /b 1)
call "%VSDIR%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
if not exist build\lua mkdir build\lua
rem Lua 5.4.3 exactly as REFramework builds it: plain C, default options
cl /nologo /c /O2 /MT /W0 /TC third_party\lua\*.c /Fobuild\lua\ || exit /b 1
cl /nologo /std:c++17 /O2 /MT /EHsc /W3 /LD requiem_coop_net.cpp build\lua\*.obj /Fobuild\ /Fe:build\requiem_coop_net.dll /link /NOLOGO || exit /b 1
echo Built build\requiem_coop_net.dll
