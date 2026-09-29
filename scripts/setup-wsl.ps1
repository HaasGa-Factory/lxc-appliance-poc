$ErrorActionPreference = 'Stop'
$statusFile = Join-Path $PSScriptRoot '..\dist\wsl-setup-status.txt'
New-Item -ItemType Directory -Force -Path (Split-Path $statusFile) | Out-Null

try {
    $wsl = Start-Process dism.exe -Wait -PassThru -ArgumentList @(
        '/online', '/enable-feature',
        '/featurename:Microsoft-Windows-Subsystem-Linux', '/all', '/norestart'
    )
    if ($wsl.ExitCode -notin 0, 3010) { throw "WSL feature failed: $($wsl.ExitCode)" }

    $vm = Start-Process dism.exe -Wait -PassThru -ArgumentList @(
        '/online', '/enable-feature',
        '/featurename:VirtualMachinePlatform', '/all', '/norestart'
    )
    if ($vm.ExitCode -notin 0, 3010) { throw "VirtualMachinePlatform failed: $($vm.ExitCode)" }

    "SUCCESS`nRestartRequired=$($wsl.ExitCode -eq 3010 -or $vm.ExitCode -eq 3010)" |
        Set-Content -Encoding ascii -LiteralPath $statusFile
}
catch {
    "FAILED`n$($_.Exception.Message)" | Set-Content -Encoding ascii -LiteralPath $statusFile
    throw
}
