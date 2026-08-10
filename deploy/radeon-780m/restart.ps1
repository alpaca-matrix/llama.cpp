# Restart llama-server on the LXC.
#
# Two things have cost a hard power cycle of pve2 in the past:
#   - restarting with a request in flight
#   - sending a request while the post-restart model is still loading
# so this checks busy state before restarting, and waits for the "listening"
# line in the journal before handing control back.
#
# usage: .\restart.ps1 [-Force]
#   -Force   restart even if the server looks busy
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$LxcHost = 'root@192.168.254.250'
$KeyPath = "$env:USERPROFILE\.ssh\id_ed25519_llamalxc"
$SshOpts = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=6', '-o', 'StrictHostKeyChecking=accept-new', '-i', $KeyPath)

function Invoke-Remote {
    param([string]$Script)
    $out = ssh @SshOpts $LxcHost $Script
    if ($LASTEXITCODE -ne 0) { throw "ssh to $LxcHost failed (exit $LASTEXITCODE)" }
    return $out
}

Write-Host "checking $LxcHost ..." -ForegroundColor DarkGray
$busy = Invoke-Remote 'curl -s -m 6 http://127.0.0.1:8080/slots 2>/dev/null | grep -c "\"is_processing\":true" || true'

if ($busy -and [int]$busy -gt 0 -and -not $Force) {
    Write-Host "  server has $busy busy slot(s) - refusing to restart mid-request." -ForegroundColor Yellow
    Write-Host "  wait for it to go idle, or re-run with -Force to restart anyway." -ForegroundColor Yellow
    exit 1
}
if ($busy -and [int]$busy -gt 0) {
    Write-Host "  server has $busy busy slot(s) but -Force was given - restarting anyway." -ForegroundColor Yellow
}

Write-Host "restarting llama-server ..." -ForegroundColor DarkGray
Invoke-Remote 'systemctl restart llama-server' | Out-Null

Write-Host "waiting for the model to finish loading ..." -ForegroundColor DarkGray -NoNewline
$loaded = $false
for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Seconds 2
    $hit = Invoke-Remote 'journalctl -u llama-server --since "-1min" --no-pager 2>/dev/null | grep -c "listening" || true'
    if ($hit -and [int]$hit -gt 0) { $loaded = $true; break }
    Write-Host '.' -NoNewline -ForegroundColor DarkGray
}
Write-Host ''

if ($loaded) {
    Write-Host "  llama-server is up and listening." -ForegroundColor Green
    Write-Host "  it may still be loading a model into memory - check .\status.ps1 before sending real traffic." -ForegroundColor DarkGray
}
else {
    Write-Host "  no 'listening' line seen after 2 minutes - check manually:" -ForegroundColor Red
    Write-Host "  ssh -i $KeyPath $LxcHost journalctl -u llama-server -n 80" -ForegroundColor DarkGray
    exit 2
}
