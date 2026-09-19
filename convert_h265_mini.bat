@echo off
rem =====================================================
rem H.265 QSV Mini Batch Converter
rem   Full GPU only: qsv decode -> vpp_qsv/scale_qsv -> hevc_qsv
rem   Rotate clockwise 90 (default) or no rotation (arg 2)
rem   No cover handling, no encoder fallback
rem =====================================================
setlocal EnableExtensions
set "FF=D:/software/ffmpeg/bin/ffmpeg.exe"
set "FP=D:/software/ffmpeg/bin/ffprobe.exe"

rem CONFIG
set "OUTDIR=%USERPROFILE%\Desktop\"
set "MAXW=1920"
set "MAXH=1080"
set "BRCAP=5000"
set "BRDEFAULT=3500"
set "MAXGAIN=24"
set "LOWPOWER=1"

rem locate ffmpeg/ffprobe
if exist "%FF%" if exist "%FP%" goto :tools_ok
where ffmpeg >nul 2>nul
if not "%ERRORLEVEL%"=="0" (
    echo [ERROR] ffmpeg not found: neither "%FF%" nor on PATH
    pause
    exit /b 1
)
where ffprobe >nul 2>nul
if not "%ERRORLEVEL%"=="0" (
    echo [ERROR] ffprobe not found: neither "%FP%" nor on PATH
    pause
    exit /b 1
)
set "FF=ffmpeg"
set "FP=ffprobe"
echo [INFO] hardcoded path missing, using ffmpeg/ffprobe from PATH
:tools_ok

if not exist "%OUTDIR%" md "%OUTDIR%"
if not "%ERRORLEVEL%"=="0" (
    echo [ERROR] cannot create output directory "%OUTDIR%"
    pause
    exit /b 1
)

rem guard: source dir != output dir
pushd "%OUTDIR%"
set "OUTDIR_FULL=%CD%"
popd
if /i "%CD%"=="%OUTDIR_FULL%" (
    echo [ERROR] source and output directory are the same: "%CD%"
    pause
    exit /b 1
)

rem rotation: no arg or arg 1 = clockwise 90, arg 2 = none
set "ROT=%~1"
if not defined ROT set "ROT=0"
if not "%ROT%"=="1" if not "%ROT%"=="2" if not "%ROT%"=="0" (
    echo [ERROR] invalid rotation "%ROT%" ^(expected no arg / 1 / 2^)
    pause
    exit /b 1
)

rem scale: long side <= MAXW, short side <= MAXH, never upscale
set "SC=min(1,min(%MAXW%/max(iw,ih),%MAXH%/min(iw,ih)))"
set "WSC=floor(iw*%SC%/2)*2"
set "HSC=floor(ih*%SC%/2)*2"

set "ROTTXT=clockwise 90"
if "%ROT%"=="2" (
    set "ROTTXT=none"
    set "VF1=scale_qsv=w='%WSC%':h='%HSC%'"
) else (
    set "VF1=vpp_qsv=transpose=clock:w='%WSC%':h='%HSC%'"
)

set "OKCNT=0"
set "FAILCNT=0"
set "SKIPCNT=0"

set "TOTAL=0"
for %%f in ("%CD%\*.mp4") do set /a TOTAL+=1
if "%TOTAL%"=="0" (
    echo [WARN] no *.mp4 files found in "%CD%\"
    pause
    exit /b 0
)

echo Source : "%CD%\"
echo FFmpeg : "%FF%"
echo Output : "%OUTDIR%"
echo Rotate : %ROTTXT%
echo Cap    : long side %MAXW% / short side %MAXH%, BR cap %BRCAP%k
echo Audio  : auto gain, ceiling %MAXGAIN% dB
echo ----------------------------------------

for %%f in ("%CD%\*.mp4") do (
    set "IN=%%~ff"
    call :process
)

echo.
echo ----------------------------------------
echo All done. OK=%OKCNT%  FAIL=%FAILCNT%  SKIP=%SKIPCNT%
pause
exit /b 0

:process
for %%I in ("%IN%") do set "NAME=%%~nxI"
if exist "%OUTDIR%\%NAME%" (
    echo [SKIP] "%NAME%" ^(already exists^)
    set /a SKIPCNT+=1
    goto :eof
)

:: --- video bitrate: stream > format > default
set "BR="
for /f "tokens=*" %%a in ('"%FP%" -v error -select_streams v:0 -show_entries stream=bit_rate -of csv=p=0 "%IN%" 2^>nul') do set "BR=%%a"
if not defined BR for /f "tokens=*" %%a in ('"%FP%" -v error -show_entries format=bit_rate -of csv=p=0 "%IN%" 2^>nul') do set "BR=%%a"
if not defined BR set "BR=N/A"
if "%BR%"=="N/A" set "BR=%BRDEFAULT%000" & echo [WARN] "%NAME%" : bitrate unknown, using %BRDEFAULT%k
set /a KB=%BR%/1000
if %KB% GTR %BRCAP% (
    set /a KB=%BRCAP%
    echo [WARN] "%NAME%" : source %BR% bps ^> %BRCAP%k, capped
)
set /a MAXKB=KB*12/10
set /a BUFKB=KB*2

:: --- audio peak scan
set "MAXVOL="
for /f "tokens=5" %%a in ('"%FF%" -hide_banner -nostats -nostdin -noautorotate -i "%IN%" -vn -af volumedetect -f null NUL 2^>^&1 ^| findstr /c:"max_volume"') do set "MAXVOL=%%a"

set "AUD=-c:a copy"
set "AUDTXT=copy"

if not defined MAXVOL goto :encode
if not "%MAXVOL:~0,1%"=="-" (
    echo [WARN] "%NAME%" : peak %MAXVOL% dB, already at or over full scale
    goto :encode
)

set "GAIN=%MAXVOL:-=%"
for /f "delims=." %%i in ("%GAIN%") do set "GI=%%i"
if "%GI%"=="0" goto :encode
if %GI% GEQ %MAXGAIN% if not "%GAIN%"=="%MAXGAIN%.0" (
    set "GAIN=%MAXGAIN%"
    echo [WARN] "%NAME%" : peak %MAXVOL% dB, gain capped to %MAXGAIN%
)

:: audio bitrate clamped to 64-192k
set "ABR="
for /f "tokens=*" %%a in ('"%FP%" -v error -select_streams a:0 -show_entries stream=bit_rate -of csv=p=0 "%IN%" 2^>nul') do set "ABR=%%a"
if not defined ABR set "ABR=128000"
if "%ABR%"=="N/A" set "ABR=128000"
set /a ABK=%ABR%/1000
if %ABK% LSS 64 set /a ABK=64
if %ABK% GTR 192 set /a ABK=192
set "AUD=-af volume=%GAIN%dB -c:a aac -b:a %ABK%k"
set "AUDTXT=+%GAIN%dB @ %ABK%k"

:encode
echo [CONV] "%NAME%" : %KB%k (peak %MAXKB%k), %ROTTXT%, audio %AUDTXT%

set "LPOPT="
if "%LOWPOWER%"=="1" set "LPOPT=-low_power 1"

"%FF%" -v error -stats -nostdin -y -noautorotate -display_rotation 0 -hwaccel qsv -hwaccel_output_format qsv -i "%IN%" ^
    -map 0:a? -filter:v:0 "%VF1%" ^
    -c:v:0 hevc_qsv %LPOPT% -preset veryfast -extbrc 1 ^
    -b:v %KB%k -maxrate %MAXKB%k -bufsize %BUFKB%k -tag:v:0 hvc1 ^
    %AUD% -movflags +faststart "%OUTDIR%\%NAME%"

if not "%ERRORLEVEL%"=="0" (set "RC=1") else (set "RC=0")

:: guard against silent failure
set "OSIZE=0"
if exist "%OUTDIR%\%NAME%" for %%A in ("%OUTDIR%\%NAME%") do set "OSIZE=%%~zA"
if "%RC%"=="0" if %OSIZE% LSS 1024 (
    echo [FAIL] "%NAME%" ^(only %OSIZE% bytes^)
    set "RC=1"
)
if not "%RC%"=="0" (
    echo [FAIL] "%NAME%"
    if exist "%OUTDIR%\%NAME%" del "%OUTDIR%\%NAME%"
    set /a FAILCNT+=1
) else (
    echo [OK] "%NAME%" ^(%OSIZE% bytes^)
    set /a OKCNT+=1
)
goto :eof
