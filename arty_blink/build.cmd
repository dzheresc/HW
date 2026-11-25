@echo off
rem build.cmd [create|build|sim|program|flash]   (default: build)
rem Set VIVADO_DIR if Vivado lives somewhere else.
setlocal
if "%VIVADO_DIR%"=="" set "VIVADO_DIR=C:\Xilinx\Vivado\2024.2"
set "STEP=%~1"
if "%STEP%"=="" set "STEP=build"
if "%STEP%"=="create" set "STEP=create_project"
if not exist "%~dp0scripts\%STEP%.tcl" (
    echo unknown step "%~1" - use create, build, sim, program or flash
    exit /b 1
)
pushd "%~dp0"
if not exist logs mkdir logs
call "%VIVADO_DIR%\bin\vivado.bat" -mode batch -nojournal -log "logs\%STEP%.log" -source "scripts\%STEP%.tcl"
set "RC=%ERRORLEVEL%"
popd
exit /b %RC%
