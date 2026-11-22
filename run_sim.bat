@echo off
REM Runs the UVM regression (8 seeds) + mutation tests on Vivado xsim and logs to run_logs\
setlocal enabledelayedexpansion
cd /d "%~dp0"
if not exist run_logs mkdir run_logs
set LOG=%~dp0run_logs\run_sim.txt
del /q run_logs\SIM_DONE.txt 2>nul
echo ==== run_sim %DATE% %TIME% ==== > "%LOG%"

REM ---- locate Vivado (known path, Desktop shortcut target, then a shallow disk search) ----
where xvlog >nul 2>&1
if errorlevel 1 (
  set VSET=
  if exist "C:\AMDDesignTools\2026.1\Vivado\settings64.bat" set "VSET=C:\AMDDesignTools\2026.1\Vivado\settings64.bat"
  if not defined VSET (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0find_vivado.ps1" > run_logs\vset.txt 2>nul
    set /p VSET=<run_logs\vset.txt
  )
  if defined VSET (
    echo Using !VSET! >> "%LOG%"
    call "!VSET!" >> "%LOG%" 2>&1
  ) else (
    echo ERROR: Vivado settings64.bat not found >> "%LOG%"
  )
)
where xvlog xelab xsim >> "%LOG%" 2>&1

REM ---- locate Python ----
set PY=
where python >nul 2>&1 && set PY=python
if not defined PY ( where py >nul 2>&1 && set PY=py -3 )
if not defined PY if defined XILINX_VIVADO (
  for /d %%P in ("%XILINX_VIVADO%\tps\win64\python-*") do if exist "%%P\python.exe" set "PY=%%P\python.exe"
)
echo PY=%PY% >> "%LOG%"

echo. >> "%LOG%"
echo ==== REGRESSION + MUTATION ==== >> "%LOG%"
%PY% scripts\run_regression.py --seeds 8 --txns 3000 --mutate %* >> "%LOG%" 2>&1
echo regression_rc=%ERRORLEVEL% >> "%LOG%"

copy /y "%TEMP%\axi4l_build\clean\build.log" run_logs\build_clean.log >nul 2>&1
copy /y "%TEMP%\axi4l_build\clean\xsim_s1.log" run_logs\xsim_clean_s1.log >nul 2>&1
echo done > run_logs\SIM_DONE.txt
echo ==== finished %TIME% ==== >> "%LOG%"
type "%LOG%"
endlocal
