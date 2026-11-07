# Registers shiori as a scheduled task that starts when Windows boots,
# whether or not anyone is logged on, and restarts it if it crashes.
# Run from an elevated PowerShell (boot triggers need administrator rights):
#   powershell -ExecutionPolicy Bypass -File scripts\install-task.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\install-task.ps1 -Uninstall
#
# This file is ASCII only: PowerShell 5.1 reads BOM-less UTF-8 as cp932.

param(
    [string]$TaskName = "shiori",
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Run this script from an elevated PowerShell (Run as administrator)."
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed task '$TaskName'."
    return
}

$root = Split-Path -Parent $PSScriptRoot
$ruby = (Get-Command ruby -ErrorAction Stop).Source
if (-not (Test-Path (Join-Path $root ".env"))) {
    throw "Create .env first (copy .env.example and fill in the tokens)."
}

$action = New-ScheduledTaskAction -Execute $ruby -Argument "bin\shiori" -WorkingDirectory $root
$trigger = New-ScheduledTaskTrigger -AtStartup
# S4U: runs without a logged-on user and without storing a password.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description "shiori: reading tracker bot (Slack Socket Mode)" -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "Registered and started task '$TaskName'."
Write-Host "Log: $(Join-Path $root 'data\shiori.log')"
