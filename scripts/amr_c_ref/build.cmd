@echo off
rem Build the standalone AMR reference decoders: FFmpeg 9.0.2 amrnbdec.c and
rem amrwbdec.c compiled unmodified against the configured FFmpeg tree at
rem the repository's parent directory, with a mingw-w64 gcc on PATH.
rem   scripts\amr_c_ref\build.cmd [amrwb^|amrnb^|all]
setlocal
set HERE=%~dp0
pushd "%HERE%..\..\.."
set FF=%CD%
popd
set WHAT=%1
if "%WHAT%"=="" set WHAT=all
echo FF=%FF%
if not "%WHAT%"=="amrnb" (
  gcc -std=gnu11 -O1 -w -I "%FF%" -o "%HERE%amrwb_ref.exe" "%HERE%amrwb_ref.c" 2>&1
  echo amrwb_ref gcc exit=%ERRORLEVEL%
)
if not "%WHAT%"=="amrwb" (
  gcc -std=gnu11 -O1 -w -I "%FF%" -o "%HERE%amrnb_ref.exe" "%HERE%amrnb_ref.c" 2>&1
  echo amrnb_ref gcc exit=%ERRORLEVEL%
)
endlocal
