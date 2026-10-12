<#
.SYNOPSIS
    Creates (or updates) the Windows scheduled task that runs Run-Plant3DReports.ps1 every morning.

.DESCRIPTION
    AutoCAD is a desktop application, so the task is registered to run in the *interactive*
    session of the current user ("Run only when user is logged on"). The PC therefore has to be
    logged on at run time - a locked screen is fine, a logged-off machine is not.

    Run this once from an elevated PowerShell on the reporting PC.

.PARAMETER Time
    Daily start time, 24h "HH:mm". Default 06:30.

.PARAMETER Weekdays
    Only run Monday-Friday.

.PARAMETER ConfigPath
    Config file handed to Run-Plant3DReports.ps1. Defaults to config.json next to this script.

.EXAMPLE
    .\Register-Plant3DReportTask.ps1 -Time 06:15 -Weekdays
#>
[CmdletBinding()]
param(
    [string]$TaskName   = 'Plant3D Daily Reports',
    [string]$Time       = '06:30',
    [switch]$Weekdays,
    [string]$ScriptPath = (Join-Path $PSScriptRoot 'Run-Plant3DReports.ps1'),
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [int]$MaxRunHours   = 2,
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'

if ($Unregister) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed task '$TaskName'."
    return
}

if (-not (Test-Path -LiteralPath $ScriptPath)) { throw "Runner script not found: $ScriptPath" }
if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath (copy config.sample.json to config.json and edit it first)" }

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" -ConfigPath `"$ConfigPath`""

$action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments -WorkingDirectory (Split-Path $ScriptPath)

$at = [datetime]::ParseExact($Time, 'HH:mm', $null)
if ($Weekdays) {
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Tuesday, Wednesday, Thursday, Friday -At $at
} else {
    $trigger = New-ScheduledTaskTrigger -Daily -At $at
}

# Interactive = "Run only when user is logged on". Required for a GUI app like AutoCAD.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

$settings = New-ScheduledTaskSettingsSet `
    -WakeToRun `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Hours $MaxRunHours)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null

$task = Get-ScheduledTask -TaskName $TaskName
Write-Host "Registered task '$TaskName'"
Write-Host "  Runs as   : $($task.Principal.UserId) (interactive, user must be logged on)"
Write-Host "  Schedule  : $(if ($Weekdays) { 'Mon-Fri' } else { 'daily' }) at $Time"
Write-Host "  Action    : $powershell $arguments"
Write-Host ''
Write-Host "Test it now with:  Start-ScheduledTask -TaskName '$TaskName'"
Write-Host "Then check the newest folder under the LogDir from your config."
