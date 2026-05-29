@echo off
setlocal EnableExtensions

REM Hermes Workspace Starter
REM - OpenWebUI can stay on port 3000
REM - Hermes Workspace UI starts on port 3001
REM - Hermes Gateway/API starts on port 8642

set "WORKSPACE_PORT=3001"
set "GATEWAY_PORT=8642"
set "WORKSPACE_DIR=~/hermes-workspace"
set "URL=http://localhost:%WORKSPACE_PORT%"

echo.
echo ==========================================
echo   Hermes Workspace Starter
echo ==========================================
echo.
echo Gateway/API:       http://localhost:%GATEWAY_PORT%
echo Workspace UI:      %URL%
echo Workspace in WSL:  %WORKSPACE_DIR%
echo.
echo Starte Hermes Gateway in einem eigenen Fenster ...
start "Hermes Gateway" cmd /k "wsl.exe bash -lc ""hermes gateway run"""

echo Starte Hermes Workspace UI auf Port %WORKSPACE_PORT% ...
REM Wichtig: bei pnpm/vite hier KEIN extra "--" verwenden, sonst ignoriert Vite den Port
REM und startet wieder auf 3000.
start "Hermes Workspace" cmd /k "wsl.exe bash -lc ""cd %WORKSPACE_DIR% && pnpm dev --host 127.0.0.1 --port %WORKSPACE_PORT%"""

echo.
echo Warte auf %URL% und oeffne dann den Browser ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$url='%URL%'; for($i=0;$i -lt 40;$i++){ try { $r=Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 1; if($r.StatusCode -ge 200){ Start-Process $url; exit 0 } } catch {}; Start-Sleep -Seconds 1 }; Start-Process $url; exit 1"
if errorlevel 1 echo Hinweis: Browser wurde geoeffnet, aber der Server war evtl. noch nicht bereit. Bitte nachladen.

echo.
echo Fertig. Falls der Browser zu frueh war: nach ein paar Sekunden neu laden.
echo Zum Beenden die beiden gestarteten Fenster mit Ctrl+C stoppen.
echo.
pause
endlocal
