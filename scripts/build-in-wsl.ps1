$ErrorActionPreference = 'Stop'
$projectWindows = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$projectWsl = '/mnt/c' + $projectWindows.Substring(2).Replace('\', '/')
$log = Join-Path $projectWindows 'dist\wsl-build.log'
New-Item -ItemType Directory -Force -Path (Split-Path $log) | Out-Null

$command = @"
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
if ! command -v debootstrap >/dev/null || ! command -v minisign >/dev/null; then
  apt-get update
  apt-get install -y --no-install-recommends debootstrap zstd ca-certificates python3 minisign jq
fi
cd '$projectWsl'
chmod +x scripts/*.sh build/*.sh bootstrap/*.sh application/*.sh tests/*.sh
if [ ! -s keys/release.key ]; then ./scripts/generate-dev-signing-key.sh; fi
./tests/test-release-security.sh
python3 -m unittest -v tests/test_app.py > dist/python-test.log 2>&1
cat dist/python-test.log
./scripts/package-app.sh
RELEASE_BASE_URL=http://192.168.1.237:8000 ./build/build-lxc.sh
./scripts/verify-artifacts.sh | tee dist/verification.log
"@

& wsl.exe -d Debian -u root -- bash -lc $command 2>&1 | Tee-Object -FilePath $log
if ($LASTEXITCODE -ne 0) { throw "WSL build failed with exit code $LASTEXITCODE" }
