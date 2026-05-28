@echo off
REM ============================================================================
REM  OrderPilot Portabel2 - Start.bat (Menue-Variante, robuste Flutter-Auflösung)
REM ----------------------------------------------------------------------------
REM  Phase-1-Stand: v0.2.0-engine-correct
REM ============================================================================

setlocal EnableDelayedExpansion
cd /d "%~dp0"

REM ============================================================================
REM  Flutter auffinden (PATH zuerst, dann typische Installationspfade)
REM ============================================================================
set "FLUTTER="

REM Versuch 1: regulärer PATH
for /f "delims=" %%I in ('where flutter.bat 2^>nul') do (
    if not defined FLUTTER set "FLUTTER=%%I"
)

REM Versuch 2: bekannte User-Installationspfade
if not defined FLUTTER (
    for %%P in (
        "%USERPROFILE%\develop\flutter\bin\flutter.bat"
        "D:\flutter\bin\flutter.bat"
        "C:\flutter\bin\flutter.bat"
        "C:\src\flutter\bin\flutter.bat"
        "C:\tools\flutter\bin\flutter.bat"
        "C:\dev\flutter\bin\flutter.bat"
        "%LOCALAPPDATA%\flutter\bin\flutter.bat"
        "%USERPROFILE%\fvm\default\bin\flutter.bat"
    ) do (
        if not defined FLUTTER if exist %%P set "FLUTTER=%%~P"
    )
)

if not defined FLUTTER (
    echo ============================================================
    echo [FEHLER] flutter konnte nicht gefunden werden.
    echo.
    echo Geprueft wurde:
    echo   - PATH ^(where flutter.bat^)
    echo   - %%USERPROFILE%%\develop\flutter\bin\
    echo   - D:\flutter\bin\
    echo   - C:\flutter\bin\, C:\src\flutter\bin\, C:\tools\flutter\bin\
    echo   - %%LOCALAPPDATA%%\flutter\bin\
    echo   - fvm-Default
    echo.
    echo Loesungsoptionen:
    echo   1. Flutter neu installieren oder den richtigen Pfad
    echo      manuell in dieser BAT bei "bekannte Installationspfade"
    echo      ergaenzen.
    echo   2. Den Flutter-bin-Pfad in den User-PATH eintragen.
    echo ============================================================
    echo.
    pause
    exit /b 1
)

REM Flutter-bin in den BAT-Session-PATH voranstellen (idempotent fuer Sub-Calls)
for %%I in ("%FLUTTER%") do set "FLUTTER_BIN=%%~dpI"
set "PATH=%FLUTTER_BIN%;%PATH%"

REM ============================================================================
REM  Menue-Schleife
REM ============================================================================

:menu
cls
echo ============================================================
echo   OrderPilot Portabel2 - Start-Menue
echo   Phase 1: v0.2.0-engine-correct
echo   Workdir: %CD%
echo   Flutter: %FLUTTER%
echo ============================================================
echo.
echo   App starten
echo     [1]  Debug-Mode      ^(schneller Start, fuer Entwicklung^)
echo     [2]  Release-Mode    ^(optimiert, fuer Nutzung^)
echo     [3]  Profile-Mode    ^(mit Performance-Overlay^)
echo.
echo   Build ^& Wartung
echo     [4]  Rust-Engine neu bauen        ^(cargo build --release^)
echo     [5]  Dependencies aktualisieren   ^(flutter pub get^)
echo     [6]  Build-Cache loeschen         ^(flutter clean^)
echo.
echo   Diagnose
echo     [7]  Tests ausfuehren             ^(flutter test + cargo test^)
echo     [8]  Flutter doctor               ^(Toolchain-Diagnose^)
echo.
echo     [0]  Beenden
echo.
echo ============================================================
choice /c 123456780 /n /m "  Auswahl [1-8, 0=Beenden]: "
set "SEL=%errorlevel%"
echo.

if "%SEL%"=="1" goto run_debug
if "%SEL%"=="2" goto run_release
if "%SEL%"=="3" goto run_profile
if "%SEL%"=="4" goto cargo_build
if "%SEL%"=="5" goto pub_get
if "%SEL%"=="6" goto build_clean
if "%SEL%"=="7" goto run_tests
if "%SEL%"=="8" goto flutter_doctor
if "%SEL%"=="9" goto end
goto menu

REM ============================================================================
REM  Aktionen
REM ============================================================================

:ensure_windows_package_config
if not exist ".dart_tool\package_config.json" (
    echo --- flutter pub get ^(Package-Konfiguration fehlt^) ---
    echo.
    call "%FLUTTER%" pub get
    exit /b !ERRORLEVEL!
)

findstr /c:"file:///home/" /c:"file:///mnt/" ".dart_tool\package_config.json" >nul 2>nul
if not errorlevel 1 (
    echo [HINWEIS] .dart_tool\package_config.json enthaelt WSL-Pfade.
    echo           Regeneriere Dependencies mit Windows-Flutter...
    echo.
    call "%FLUTTER%" pub get
    exit /b !ERRORLEVEL!
)

exit /b 0

:run_debug
call :ensure_windows_package_config
if errorlevel 1 goto after_action
echo --- flutter run -d windows --debug ---
echo     ^(Beenden mit 'q' im laufenden Fenster^)
echo.
call "%FLUTTER%" run -d windows --debug
goto after_action

:run_release
call :ensure_windows_package_config
if errorlevel 1 goto after_action
echo --- flutter run -d windows --release ---
echo     ^(Beenden mit 'q' im laufenden Fenster^)
echo.
call "%FLUTTER%" run -d windows --release
goto after_action

:run_profile
call :ensure_windows_package_config
if errorlevel 1 goto after_action
echo --- flutter run -d windows --profile ---
echo     ^(Beenden mit 'q' im laufenden Fenster^)
echo.
call "%FLUTTER%" run -d windows --profile
goto after_action

:cargo_build
echo --- cargo build --release ^(rust\trading_engine^) ---
echo.
pushd rust\trading_engine
cargo build --release
set "CARGO_EXIT_CODE=%ERRORLEVEL%"
popd
if "%CARGO_EXIT_CODE%"=="0" (
    echo.
    echo [OK] Rust-Engine erfolgreich gebaut.
    echo      Artefakt: rust\trading_engine\target\release\trading_engine.dll
) else (
    echo.
    echo [FEHLER] cargo build fehlgeschlagen ^(Exit %CARGO_EXIT_CODE%^).
    echo          Ist Rust installiert? rustup show
)
goto after_action

:pub_get
echo --- flutter pub get ---
echo.
call "%FLUTTER%" pub get
goto after_action

:build_clean
echo --- flutter clean ---
echo.
call "%FLUTTER%" clean
echo.
echo --- cargo clean ^(rust\trading_engine^) ---
pushd rust\trading_engine
cargo clean
popd
echo.
echo [OK] Build-Cache geloescht. Naechster Build dauert laenger.
goto after_action

:run_tests
call :ensure_windows_package_config
if errorlevel 1 goto after_action
echo --- flutter test ---
echo.
call "%FLUTTER%" test
echo.
echo --- cargo test ^(rust\trading_engine^) ---
pushd rust\trading_engine
cargo test --release
set "CARGO_EXIT_CODE=%ERRORLEVEL%"
popd
echo.
if "%CARGO_EXIT_CODE%"=="0" (
    echo [OK] Test-Suite abgeschlossen.
) else (
    echo [HINWEIS] cargo test Exit %CARGO_EXIT_CODE% ^(WSL2 ist kanonische Test-Umgebung^).
)
goto after_action

:flutter_doctor
echo --- flutter doctor -v ---
echo.
call "%FLUTTER%" doctor -v
goto after_action

REM ============================================================================
REM  Nach Aktion: zurueck ins Menue
REM ============================================================================

:after_action
echo.
echo ============================================================
pause
goto menu

:end
echo.
echo Tschuess.
endlocal
exit /b 0
