@echo off
setlocal
cd /d "%~dp0"
set TRIED_INSTALL=

:find
rem Git Bash from the usual install roots, then next to any git.exe on PATH. Never WSL's System32\bash.exe.
for %%D in ("%ProgramW6432%" "%ProgramFiles%" "%ProgramFiles(x86)%" "%LOCALAPPDATA%\Programs") do (
  if exist "%%~D\Git\bin\bash.exe" (set "BASH=%%~D\Git\bin\bash.exe" & goto run)
)
for /f "delims=" %%G in ('where git 2^>nul') do (
  if exist "%%~dpG..\bin\bash.exe" (set "BASH=%%~dpG..\bin\bash.exe" & goto run)
)

if defined TRIED_INSTALL goto nogit
echo Git for Windows (Git Bash) is required and was not found.
where winget >nul 2>nul || goto nogit
choice /c YN /m "Install Git for Windows now with winget"
if errorlevel 2 goto nogit
set TRIED_INSTALL=1
winget install -e --id Git.Git --source winget --accept-package-agreements --accept-source-agreements
goto find

:nogit
echo Install Git for Windows from https://git-scm.com/download/win and run this again.
pause
exit /b 1

:run
rem igncr: the script still runs if git checked it out with CRLF line endings.
"%BASH%" -o igncr setup-vibeue.sh %*
set RC=%ERRORLEVEL%
pause
exit /b %RC%
