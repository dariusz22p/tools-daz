@echo off
REM Wrapper script for sharepoint_dl.py (Windows)
REM Automatically sets up a virtual environment and installs dependencies.
REM
REM Usage:
REM   sharepoint_dl.bat [--browser BROWSER] <sharepoint_stream_url> [output_filename]

setlocal

set "SCRIPT_DIR=%~dp0"
set "VENV_DIR=%SCRIPT_DIR%.venv"
set "PYTHON_SCRIPT=%SCRIPT_DIR%sharepoint_dl.py"

REM Find Python
where python >nul 2>&1
if %errorlevel% neq 0 (
    where python3 >nul 2>&1
    if %errorlevel% neq 0 (
        echo ERROR: Python 3.7+ not found. Please install Python 3. >&2
        exit /b 1
    )
    set "PYTHON=python3"
) else (
    set "PYTHON=python"
)

REM Create venv if it doesn't exist
if not exist "%VENV_DIR%\Scripts\activate.bat" (
    echo Creating virtual environment in %VENV_DIR% ...
    %PYTHON% -m venv "%VENV_DIR%"
)

REM Activate venv
call "%VENV_DIR%\Scripts\activate.bat"

REM Install dependencies if missing
python -c "import requests" >nul 2>&1
if %errorlevel% neq 0 (
    echo Installing Python dependencies...
    pip install --quiet requests cryptography pywin32
)
python -c "import cryptography" >nul 2>&1
if %errorlevel% neq 0 (
    pip install --quiet cryptography
)

REM Run the downloader
python "%PYTHON_SCRIPT%" %*
