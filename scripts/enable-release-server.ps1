$ErrorActionPreference = 'Stop'
$ruleName = 'LXC Appliance POC release server'
$python = 'C:\Users\ghaas\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
$existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

if ($existing) {
    Set-NetFirewallRule -DisplayName $ruleName -Enabled True | Out-Null
} else {
    New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
        -Protocol TCP -LocalPort 8000 -Program $python -Profile Any `
        -RemoteAddress LocalSubnet | Out-Null
}
