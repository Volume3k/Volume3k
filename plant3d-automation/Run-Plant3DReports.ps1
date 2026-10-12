<#
.SYNOPSIS
    Unattended run of Plant 3D project report commands (for Windows Task Scheduler).

.DESCRIPTION
    Launches AutoCAD Plant 3D 2026 with a drawing that belongs to the target project
    (so the project loads automatically), runs a generated AutoCAD script (.scr) that
    executes the configured report commands, saves the scratch drawing and quits.

    Everything is driven from a JSON config file (see config.sample.json).

    Exit codes:
      0  report commands completed and AutoCAD exited normally
      1  AutoCAD exited but the completion marker was never written (crash / dialog closed)
      2  timed out (most likely stuck on a dialog) - AutoCAD was killed, screenshot saved
      3  pre-flight failure (bad config, missing files, AutoCAD already running, ...)

.PARAMETER ConfigPath
    Path to the JSON config. Defaults to config.json next to this script.

.PARAMETER DryRun
    Generate the .scr and print the command line, but do not launch anything.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File Run-Plant3DReports.ps1 -ConfigPath C:\Plant3D\Automation\config.json
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [switch]$DryRun
)

Set-StrictMode -Version 2
$script:RunLogFile = $null
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Write-Host $line
    if ($script:RunLogFile) { Add-Content -Path $script:RunLogFile -Value $line }
}

function Fail {
    param([string]$Message, [int]$Code = 3)
    Write-Log $Message 'ERROR'
    exit $Code
}

function Get-Setting {
    # Returns $Config.<Name> if present and non-empty, else $Default.
    param($Config, [string]$Name, $Default)
    $prop = $Config.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    $value = $prop.Value
    if ($null -eq $value) { return $Default }
    if (($value -is [string]) -and [string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

function ConvertTo-LispPath {
    # AutoLISP strings treat backslash as escape; forward slashes are safe.
    param([string]$Path)
    return ($Path -replace '\\', '/')
}

function Save-Screenshot {
    # Best effort: grab the primary screen so a blocking dialog can be diagnosed.
    param([string]$Path)
    try {
        Add-Type -AssemblyName System.Drawing, System.Windows.Forms
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $gfx = [System.Drawing.Graphics]::FromImage($bmp)
        $gfx.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
        $gfx.Dispose(); $bmp.Dispose()
        Write-Log "Screenshot saved: $Path"
    } catch {
        Write-Log "Screenshot failed (no interactive desktop?): $($_.Exception.Message)" 'WARN'
    }
}

function Remove-OldRunFolders {
    param([string]$LogDir, [int]$KeepDays)
    if ($KeepDays -le 0) { return }
    $cutoff = (Get-Date).AddDays(-$KeepDays)
    Get-ChildItem -Path $LogDir -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        ForEach-Object {
            try { Remove-Item $_.FullName -Recurse -Force; Write-Log "Removed old run folder $($_.Name)" }
            catch { Write-Log "Could not remove $($_.FullName): $($_.Exception.Message)" 'WARN' }
        }
}

function Wait-ProcessWithTimeout {
    # Returns $true if the process exited within the timeout.
    param([System.Diagnostics.Process]$Process, [int]$TimeoutMinutes)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while (-not $Process.HasExited) {
        if ((Get-Date) -gt $deadline) { return $false }
        Start-Sleep -Seconds 5
    }
    return $true
}

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "Config not found: $ConfigPath"; exit 3
}
try { $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json }
catch { Write-Host "Config is not valid JSON: $($_.Exception.Message)"; exit 3 }

$Mode            = Get-Setting $cfg 'Mode' 'Acad'
$AcadExe         = Get-Setting $cfg 'AcadExe' 'C:\Program Files\Autodesk\AutoCAD 2026\acad.exe'
$Language        = Get-Setting $cfg 'Language' 'en-US'
$AcadProfile         = Get-Setting $cfg 'Profile' ''
$ProjectDrawing  = Get-Setting $cfg 'ProjectDrawing' ''
$StartupDelayMs  = [int](Get-Setting $cfg 'StartupDelayMs' 15000)
$PreCommands     = @(Get-Setting $cfg 'PreCommands' @())
$ReportCommands  = @(Get-Setting $cfg 'ReportCommands' @())
$TimeoutMinutes  = [int](Get-Setting $cfg 'TimeoutMinutes' 45)
$LogDir          = Get-Setting $cfg 'LogDir' (Join-Path $PSScriptRoot 'Logs')
$KeepLogDays     = [int](Get-Setting $cfg 'KeepLogDays' 30)
$AllowWhenAcadRunning = [bool](Get-Setting $cfg 'AllowWhenAcadRunning' $false)
$ReportCreatorExe  = Get-Setting $cfg 'ReportCreatorExe' 'C:\Program Files\Autodesk\AutoCAD 2026\PLNT3D\PnPReportCreator.exe'
$ReportCreatorJobs = @(Get-Setting $cfg 'ReportCreatorJobs' @())

# DELAY accepts 0..32767 ms per call; split longer delays into several lines.
if ($StartupDelayMs -lt 0) { $StartupDelayMs = 0 }

# ---------------------------------------------------------------------------
# Run folder + logging
# ---------------------------------------------------------------------------
$runStamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$runDir   = Join-Path $LogDir $runStamp
New-Item -ItemType Directory -Path $runDir -Force | Out-Null
$script:RunLogFile = Join-Path $runDir 'run.log'

Write-Log "=== Plant 3D report automation start (mode: $Mode) ==="
Write-Log "Config: $ConfigPath"
Write-Log "Run folder: $runDir"
Remove-OldRunFolders -LogDir $LogDir -KeepDays $KeepLogDays

# ---------------------------------------------------------------------------
# Mode: ReportCreator (headless, no AutoCAD session)
# ---------------------------------------------------------------------------
if ($Mode -eq 'ReportCreator') {
    if (-not (Test-Path -LiteralPath $ReportCreatorExe)) { Fail "Report Creator not found: $ReportCreatorExe" }
    if ($ReportCreatorJobs.Count -eq 0) { Fail 'No ReportCreatorJobs configured.' }

    $failed = 0
    foreach ($job in $ReportCreatorJobs) {
        $project = Get-Setting $job 'Project' ''
        $config  = Get-Setting $job 'Config'  ''
        if (-not $project -or -not $config) { Write-Log "Job skipped: needs both Project and Config. $($job | ConvertTo-Json -Compress)" 'WARN'; $failed++; continue }
        if (-not (Test-Path -LiteralPath $project)) { Write-Log "Project file missing: $project" 'ERROR'; $failed++; continue }
        if (-not (Test-Path -LiteralPath $config))  { Write-Log "Report config missing: $config" 'ERROR'; $failed++; continue }

        $rcArgs = @('/PROJECT', "`"$project`"", '/CONFIG', "`"$config`"", '/HIDDEN', '/QUIET')
        $dwgs = @(Get-Setting $job 'Drawings' @())
        if ($dwgs.Count -gt 0) { $rcArgs += @('/DWG', "`"$($dwgs -join ',')`"") }

        Write-Log "Report Creator: `"$ReportCreatorExe`" $($rcArgs -join ' ')"
        if ($DryRun) { continue }

        $p = Start-Process -FilePath $ReportCreatorExe -ArgumentList $rcArgs -PassThru
        if (-not (Wait-ProcessWithTimeout -Process $p -TimeoutMinutes $TimeoutMinutes)) {
            Save-Screenshot -Path (Join-Path $runDir "timeout-$($p.Id).png")
            Write-Log "Report Creator timed out after $TimeoutMinutes min; killing PID $($p.Id)" 'ERROR'
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            $failed++
            continue
        }
        Write-Log "Report Creator exit code: $($p.ExitCode)"
        if ($p.ExitCode -ne 0) { $failed++ }
    }

    if ($failed -gt 0) { Fail "$failed Report Creator job(s) failed." 1 }
    Write-Log '=== All Report Creator jobs finished ==='
    exit 0
}

# ---------------------------------------------------------------------------
# Mode: Acad (full Plant 3D session driven by a script)
# ---------------------------------------------------------------------------
if ($Mode -ne 'Acad') { Fail "Unknown Mode '$Mode'. Use 'Acad' or 'ReportCreator'." }

if (-not (Test-Path -LiteralPath $AcadExe))        { Fail "acad.exe not found: $AcadExe" }
if (-not $ProjectDrawing)                           { Fail 'ProjectDrawing is not set in the config.' }
if (-not (Test-Path -LiteralPath $ProjectDrawing))  { Fail "ProjectDrawing not found: $ProjectDrawing" }
if ($ReportCommands.Count -eq 0)                    { Fail 'ReportCommands is empty - nothing to run.' }

$running = @(Get-Process -Name 'acad' -ErrorAction SilentlyContinue)
if ($running.Count -gt 0 -and -not $AllowWhenAcadRunning) {
    Fail "AutoCAD is already running (PID $($running.Id -join ', ')). Aborting so an open session is not disturbed. Set AllowWhenAcadRunning=true to override."
}

# Marker + command log paths the script will write to.
$doneFile     = Join-Path $runDir 'DONE.txt'
$cmdLogFile   = Join-Path $runDir 'acad-commandlog.txt'
$scrFile      = Join-Path $runDir 'reports.scr'

# ---------------------------------------------------------------------------
# Build the AutoCAD script
#   Rules: one command/response per line, NO blank lines (a blank line = Enter,
#   which repeats the last command), and a trailing newline on the last line.
# ---------------------------------------------------------------------------
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("; Generated $(Get-Date -Format s) by Run-Plant3DReports.ps1 - do not edit")
$lines.Add('(setvar "CMDECHO" 0)')
$lines.Add('(setvar "EXPERT" 5)')                       # suppress most "Are you sure?" prompts

$remaining = $StartupDelayMs
while ($remaining -gt 0) {                              # give Plant 3D time to finish loading the project
    $chunk = [Math]::Min($remaining, 32767)
    $lines.Add("_.DELAY $chunk")
    $remaining -= $chunk
}

$lines.Add('(setq p3d-logmode (getvar "LOGFILEMODE"))')
$lines.Add('(setvar "LOGFILEMODE" 1)')                  # capture command-line output

foreach ($c in $PreCommands)    { if ($c -and $c.Trim()) { $lines.Add($c.Trim()) } }
foreach ($c in $ReportCommands) { if ($c -and $c.Trim()) { $lines.Add($c.Trim()) } }

$lines.Add('(setvar "LOGFILEMODE" 0)')
$lines.Add("(vl-file-copy (getvar `"LOGFILENAME`") `"$(ConvertTo-LispPath $cmdLogFile)`")")
$lines.Add('(setvar "LOGFILEMODE" p3d-logmode)')
$lines.Add("(progn (setq p3d-f (open `"$(ConvertTo-LispPath $doneFile)`" `"w`")) (write-line `"OK`" p3d-f) (close p3d-f))")
$lines.Add('_.QSAVE')                                   # clears the modified flag so QUIT needs no answer
$lines.Add('_.QUIT')

$scrText = ($lines -join "`r`n") + "`r`n"
[System.IO.File]::WriteAllText($scrFile, $scrText, [System.Text.Encoding]::Default)
Write-Log "Script written: $scrFile"
Write-Log ("Script content:`r`n" + $scrText)

# ---------------------------------------------------------------------------
# Launch AutoCAD Plant 3D
# ---------------------------------------------------------------------------
$acadArgs = @("`"$ProjectDrawing`"", '/product', 'PLNT3D', '/language', "`"$Language`"", '/nologo', '/b', "`"$scrFile`"")
if ($AcadProfile) { $acadArgs += @('/p', "`"$AcadProfile`"") }

Write-Log "Launching: `"$AcadExe`" $($acadArgs -join ' ')"
if ($DryRun) { Write-Log 'DryRun - not launching.'; exit 0 }

$proc = Start-Process -FilePath $AcadExe -ArgumentList $acadArgs -WorkingDirectory (Split-Path $ProjectDrawing) -PassThru
Write-Log "acad.exe started, PID $($proc.Id). Timeout $TimeoutMinutes min."

if (-not (Wait-ProcessWithTimeout -Process $proc -TimeoutMinutes $TimeoutMinutes)) {
    Save-Screenshot -Path (Join-Path $runDir 'timeout.png')
    Write-Log "Timed out after $TimeoutMinutes min - AutoCAD is probably waiting on a dialog. Killing PID $($proc.Id)." 'ERROR'
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Fail 'Run timed out.' 2
}

Write-Log "acad.exe exited with code $($proc.ExitCode)."
if (Test-Path -LiteralPath $doneFile) {
    Write-Log '=== Report commands completed successfully ==='
    exit 0
}

Fail 'AutoCAD exited before the completion marker was written (crash, or a dialog was closed). Check acad-commandlog.txt.' 1
