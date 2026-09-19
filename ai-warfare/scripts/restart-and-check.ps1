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
                      +exec server/server.cfg
                      +set sv_licenseKey <resolved key>

    sv_licenseKey is passed on the command line, never written to disk.
    server.cfg deliberately does not set it, so the command line is the only
    source for that convar.

.PARAMETER Seconds
    How long to let the server run before stopping it. Default 45.

.PARAMETER KeepRunning
    If set, do not stop the server after the check window — just report on
    the log collected so far.

.PARAMETER Filter
    Extra regex (in addition to the built-in error patterns) to also flag
    as a failure line.

.PARAMETER LicenseKey
    FiveM license key. If omitted, resolved in this order: the
    FIVEM_LICENSE_KEY environment variable, then the first non-empty,
    non-comment line of server\license.key (gitignored; see
    server\license.key.example).

.NOTES
    PowerShell 5.1 compatible. This script has NOT been run against a real
    FXServer.exe in this environment (no network access to runtime.fivem.net
    from the dev container) — see README.md "Verified vs. unverified".
#>

[CmdletBinding()]
param(
    [int]$Seconds = 45,
    [switch]$KeepRunning,
    [string]$Filter,
    [string]$LicenseKey
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

    $licenseKeyValue = $null
    $licenseKeySource = $null
    $licenseKeyFile = Join-Path $RepoRoot 'server\license.key'

    if ($LicenseKey) {
        $licenseKeyValue = $LicenseKey
        $licenseKeySource = '-LicenseKey argument'
    } elseif ($env:FIVEM_LICENSE_KEY) {
        $licenseKeyValue = $env:FIVEM_LICENSE_KEY
        $licenseKeySource = 'FIVEM_LICENSE_KEY environment variable'
    } elseif (Test-Path $licenseKeyFile) {
        $fileLine = Get-Content -Path $licenseKeyFile -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -First 1
        if ($fileLine) {
            $licenseKeyValue = $fileLine
            $licenseKeySource = 'server\license.key'
        }
    }

    if (-not $licenseKeyValue) {
        throw "No FiveM license key found. Provide one via -LicenseKey <key>, the FIVEM_LICENSE_KEY environment variable, or by creating server\license.key (see server\license.key.example; the file is gitignored and never committed). Get a free key at https://portal.cfx.re"
    }

    $keyPrefix = $licenseKeyValue.Substring(0, [Math]::Min(5, $licenseKeyValue.Length))
    Write-Host "license key: loaded from $licenseKeySource ($keyPrefix…, $($licenseKeyValue.Length) chars)"

    New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $logPath = Join-Path $LogsDir "fxserver-$timestamp.log"
    $stdoutPath = "$logPath.stdout.tmp"
    $stderrPath = "$logPath.stderr.tmp"

    # Key last: server.cfg deliberately does not set sv_licenseKey, so there is
    # nothing to race, and every launcher in scripts/ builds the same order.
    $argList = @(
        '+set', 'citizen_dir', "`"$CitizenDir`"",
        '+exec', 'server/server.cfg',
        '+set', 'sv_licenseKey', $licenseKeyValue
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
