$ErrorActionPreference = 'Stop'
$projectWindows = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$projectWsl = '/mnt/c' + $projectWindows.Substring(2).Replace('\', '/')
$log = Join-Path $projectWindows 'dist\verification.log'
$command = "cd '$projectWsl' && chmod +x scripts/verify-artifacts.sh && ./scripts/verify-artifacts.sh"

& wsl.exe -d Debian -u root -- bash -lc $command 2>&1 | Tee-Object -FilePath $log
if ($LASTEXITCODE -ne 0) { throw "Artifact verification failed with exit code $LASTEXITCODE" }
