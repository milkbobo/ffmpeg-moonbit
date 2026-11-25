@echo off
rem Build the standalone ADPCM reference decoder (FFmpeg 9.0.2 adpcm.c and
rem adpcm_data.c compiled unmodified against the configured FFmpeg tree at
rem the repository's parent directory) with the mingw-w64 gcc on PATH.
setlocal
set HERE=%~dp0
pushd "%HERE%..\..\.."
set FF=%CD%
popd
gcc -std=gnu11 -O1 -w -I "%FF%" -o "%HERE%adpcm_ref.exe" "%HERE%adpcm_ref.c" 2>&1
echo adpcm_ref gcc exit=%ERRORLEVEL%
endlocal
