# Keeps WSL running after you log on, so the systemd unit scripts/shiori.service
# (which runs shiori inside WSL) stays up. Use this instead of install-task.ps1 when
# Windows cannot run Ruby itself, e.g. when Smart App Control blocks it.
# Run from an elevated PowerShell:
#   powershell -ExecutionPolicy Bypass -File scripts\install-wsl-task.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\install-wsl-task.ps1 -Uninstall
#
# This file is ASCII only: PowerShell 5.1 reads BOM-less UTF-8 as cp932.

param(
    [string]$TaskName = "shiori",
    [string]$Distro = "Ubuntu-24.04",
    [switch]$Uninstall
)

$ErrorActionPreference = "Stop"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "Run this script from an elevated PowerShell (Run as administrator)."
}

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
if ($Uninstall) {
    Write-Host "Removed task '$TaskName'."
    return
}

# WSL shuts the distro down when no wsl.exe client is attached, so keep one attached.
# A hidden PowerShell hosts it so no console window stays open.
$user = "$env:USERDOMAIN\$env:USERNAME"
$action = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument "-NoProfile -WindowStyle Hidden -Command `"wsl.exe -d $Distro --exec sleep infinity`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) `
    -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description "shiori: keep WSL ($Distro) running for the shiori service" | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host "Registered and started task '$TaskName' (keeps $Distro running)."
Write-Host "Check the bot with: wsl -d $Distro -- systemctl --user status shiori"
