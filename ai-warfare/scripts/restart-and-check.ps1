<#
.SYNOPSIS
    Starts FXServer, lets it run for a fixed window, captures its log, stops
    it, and greps the log for error signatures (ENGINE-SPEC.md §3.5 loop).

.DESCRIPTION
    Layout decision (see server/server.cfg header and README.md for the full
    rationale): FXServer.exe is launched with its WORKING DIRECTORY set to
    the ai-warfare REPO ROOT, and server.cfg is loaded via a path relative
    to that root (+exec server/server.cfg). This lets one resources/ folder
    at the repo root serve both resources/[mission]/ (owned by the Lua
    worker) and the standard cfx-server-data resources that get-server.ps1
    copies alongside it.

    Command line used:
        FXServer.exe +set citizen_dir "<repo>\server\artifact\citizen"
                      +set sv_licenseKey <FIVEM_LICENSE_KEY>
                      +exec server/server.cfg

    sv_licenseKey is passed on the command line AFTER +exec so it overrides
    the "CHANGEME" placeholder baked into server.cfg, without ever writing
    the real key to disk.

.PARAMETER Seconds
    How long to let the server run before stopping it. Default 45.

.PARAMETER KeepRunning
    If set, do not stop the server after the check window — just report on
    the log collected so far.

.PARAMETER Filter
    Extra regex (in addition to the built-in error patterns) to also flag
    as a failure line.

.NOTES
    PowerShell 5.1 compatible. This script has NOT been run against a real
    FXServer.exe in this environment (no network access to runtime.fivem.net
    from the dev container) — see README.md "Verified vs. unverified".
#>

[CmdletBinding()]
param(
    [int]$Seconds = 45,
    [switch]$KeepRunning,
    [string]$Filter
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot    = Split-Path -Parent $PSScriptRoot
$ArtifactDir = Join-Path $RepoRoot 'server\artifact'
$FxServerExe = Join-Path $ArtifactDir 'FXServer.exe'
$CitizenDir  = Join-Path $ArtifactDir 'citizen'
$LogsDir     = Join-Path $RepoRoot 'logs'

$builtinPattern = 'error|failed to load|exception|SCRIPT ERROR|Couldn''t find resource|not found'
if ($Filter) {
    $combinedPattern = "(?i)(?:$builtinPattern)|(?:$Filter)"
} else {
    $combinedPattern = "(?i)(?:$builtinPattern)"
}

try {
    if (-not (Test-Path $FxServerExe)) {
        throw "FXServer.exe not found at $FxServerExe. Run scripts\get-server.ps1 first."
    }

    if (-not $env:FIVEM_LICENSE_KEY -or $env:FIVEM_LICENSE_KEY -eq '') {
        throw "Environment variable FIVEM_LICENSE_KEY is not set. Get a free key at https://portal.cfx.re and run: `$env:FIVEM_LICENSE_KEY = '<key>'"
    }

    New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $LogsDir "fxserver-$timestamp.log"
    $stdoutPath = "$logPath.stdout.tmp"
    $stderrPath = "$logPath.stderr.tmp"

    $argList = @(
        '+set', 'citizen_dir', "`"$CitizenDir`"",
        '+set', 'sv_licenseKey', $env:FIVEM_LICENSE_KEY,
        '+exec', 'server/server.cfg'
    )

    Write-Host "==> Starting FXServer for $Seconds second(s)..." -ForegroundColor Cyan
    Write-Host "    Working directory: $RepoRoot"
    Write-Host "    Log: $logPath"

    $proc = Start-Process -FilePath $FxServerExe `
        -ArgumentList $argList `
        -WorkingDirectory $RepoRoot `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru `
        -WindowStyle Hidden

    Start-Sleep -Seconds $Seconds

    if (-not $KeepRunning) {
        Write-Host "==> Stopping FXServer (PID $($proc.Id))..." -ForegroundColor Cyan
        if (-not $proc.HasExited) {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            $proc.WaitForExit(10000) | Out-Null
        }
    } else {
        Write-Host "==> -KeepRunning set; leaving FXServer running (PID $($proc.Id))." -ForegroundColor Yellow
    }

    # Merge stdout+stderr into the final timestamped log file.
    $lines = @()
    if (Test-Path $stdoutPath) { $lines += Get-Content -Path $stdoutPath -ErrorAction SilentlyContinue }
    if (Test-Path $stderrPath) { $lines += Get-Content -Path $stderrPath -ErrorAction SilentlyContinue }
    $lines | Set-Content -Path $logPath
    Remove-Item -Path $stdoutPath, $stderrPath -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "==> Scanning log for error signatures..." -ForegroundColor Cyan
    $matches = $lines | Select-String -Pattern $combinedPattern

    if ($matches) {
        Write-Host ""
        foreach ($m in $matches) {
            Write-Host $m.Line -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "RESULT: FAIL ($($matches.Count) matching line(s)). Log: $logPath" -ForegroundColor Red
        exit 1
    } else {
        Write-Host ""
        Write-Host "RESULT: PASS (no error signatures found). Log: $logPath" -ForegroundColor Green
        exit 0
    }
} catch {
    Write-Host ""
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    exit 1
}
