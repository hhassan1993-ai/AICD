<#
.SYNOPSIS
    Single-command Windows bootstrap for the ai-warfare FXServer test server:
    preflight checks, license key setup, download, and run-and-check, in one
    paste.

.DESCRIPTION
    Collapses the two-script manual flow (scripts/get-server.ps1 then
    scripts/restart-and-check.ps1) and its three common gotchas — PowerShell
    execution policy, 7-Zip not on PATH, and license key setup — into one
    command:

        powershell -ExecutionPolicy Bypass -File .\scripts\bootstrap.ps1 -LicenseKey <key> -InstallPrereqs

    Steps, each printed as a "==>" banner:
      1. Preflight    - PowerShell version, git, 7z.exe (checking the default
                         7-Zip install locations before declaring it missing).
                         With -InstallPrereqs, installs missing prereqs via
                         winget and re-checks; otherwise stops and prints the
                         exact commands to run.
      2. License key  - writes -LicenseKey to server/license.key (never
                         overwriting a differing existing file without
                         -Force), or verifies a key is resolvable some other
                         way (env var / existing file).
      3. Get server   - runs scripts/get-server.ps1 (unless -SkipGetServer),
                         forwarding -ArtifactUrl.
      4. Run and check- runs scripts/restart-and-check.ps1, forwarding
                         -Seconds and -KeepRunning.
      5. Verdict      - PASS/FAIL, newest log file, and the next action.

    This script has NOT been run against a real Windows machine from this
    environment (no Windows host, no network path to winget/runtime.fivem.net
    from the container that authored it) — see README.md "Verified vs.
    unverified". It is a straight-line composition of the two scripts it
    wraps, which are themselves unverified for the same reason.

.PARAMETER LicenseKey
    Optional. FiveM license key. If given, written to server/license.key.
    Never printed; only its source, a 5-character prefix, and its length are
    logged. Passing it as an argument leaves it visible in shell history and
    the process list — prefer creating server/license.key by hand instead.

.PARAMETER Force
    Required to overwrite an existing server/license.key whose content
    differs from -LicenseKey. Without it, the existing file is left alone.

.PARAMETER InstallPrereqs
    Opt in to installing missing prerequisites (git, 7-Zip) via winget. This
    is the only switch that may change machine state; each install is
    announced before it runs. Without it, missing prerequisites are only
    reported, along with the exact winget command to fix them, and the
    script exits non-zero.

.PARAMETER ArtifactUrl
    Optional. Forwarded to scripts/get-server.ps1 -ArtifactUrl.

.PARAMETER Seconds
    Optional. Forwarded to scripts/restart-and-check.ps1 -Seconds.

.PARAMETER KeepRunning
    Optional. Forwarded to scripts/restart-and-check.ps1 -KeepRunning, for
    connecting a game client afterwards.

.PARAMETER SkipGetServer
    Optional. Skip the download step when server/artifact/FXServer.exe
    already exists.

.NOTES
    PowerShell 5.1 compatible.
#>

[CmdletBinding()]
param(
    [string]$LicenseKey,
    [switch]$Force,
    [switch]$InstallPrereqs,
    [string]$ArtifactUrl,
    [int]$Seconds = 45,
    [switch]$KeepRunning,
    [switch]$SkipGetServer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot        = Split-Path -Parent $PSScriptRoot
$ServerDir       = Join-Path $RepoRoot 'server'
$ArtifactDir     = Join-Path $ServerDir 'artifact'
$FxServerExe     = Join-Path $ArtifactDir 'FXServer.exe'
$LicenseKeyFile  = Join-Path $ServerDir 'license.key'
$LogsDir         = Join-Path $RepoRoot 'logs'
$GetServerScript = Join-Path $PSScriptRoot 'get-server.ps1'
$RestartScript   = Join-Path $PSScriptRoot 'restart-and-check.ps1'

function Write-Step($msg) {
    Write-Host ""
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Get-NewestLogPath {
    if (-not (Test-Path $LogsDir)) { return $null }
    $newest = Get-ChildItem -Path $LogsDir -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($newest) { return $newest.FullName }
    return $null
}

try {
    # ---------------------------------------------------------------
    # 1. Preflight
    # ---------------------------------------------------------------
    Write-Step "Preflight checks"

    $checks = @()

    # PowerShell version
    $psOk = $PSVersionTable.PSVersion.Major -ge 5
    $checks += [pscustomobject]@{
        Name   = 'PowerShell >= 5'
        Status = $(if ($psOk) { 'OK' } else { 'MISSING' })
        Fix    = 'Upgrade PowerShell (install PowerShell 7: https://aka.ms/powershell)'
    }

    # git
    $gitCmd = Get-Command 'git' -ErrorAction SilentlyContinue
    $gitOk = [bool]$gitCmd
    $checks += [pscustomobject]@{
        Name   = 'git on PATH'
        Status = $(if ($gitOk) { 'OK' } else { 'MISSING' })
        Fix    = 'winget install --id Git.Git -e'
    }

    # 7z.exe — check PATH, then default install locations
    $sevenZipCmd = Get-Command '7z.exe' -ErrorAction SilentlyContinue
    $sevenZipOk = [bool]$sevenZipCmd
    $sevenZipResolvedNote = $null
    if (-not $sevenZipOk) {
        $defaultLocations = @(
            'C:\Program Files\7-Zip\7z.exe',
            'C:\Program Files (x86)\7-Zip\7z.exe'
        )
        foreach ($loc in $defaultLocations) {
            if (Test-Path $loc) {
                $folder = Split-Path -Parent $loc
                $env:PATH = "$folder;$env:PATH"
                $sevenZipOk = $true
                $sevenZipResolvedNote = "found at $loc, added to PATH for this session"
                break
            }
        }
    }
    $checks += [pscustomobject]@{
        Name   = '7z.exe on PATH'
        Status = $(if ($sevenZipOk) { 'OK' } else { 'MISSING' })
        Fix    = 'winget install --id 7zip.7zip -e'
    }

    Write-Host ""
    Write-Host "Check              Status" -ForegroundColor DarkGray
    Write-Host "-----              ------" -ForegroundColor DarkGray
    foreach ($c in $checks) {
        $color = if ($c.Status -eq 'OK') { 'Green' } else { 'Red' }
        Write-Host ("{0,-18} {1}" -f $c.Name, $c.Status) -ForegroundColor $color
    }
    if ($sevenZipResolvedNote) {
        Write-Host "  (7-Zip $sevenZipResolvedNote)" -ForegroundColor DarkYellow
    }

    $missing = $checks | Where-Object { $_.Status -eq 'MISSING' }

    if ($missing) {
        if ($InstallPrereqs) {
            Write-Step "Installing missing prerequisites via winget"
            foreach ($m in $missing) {
                if ($m.Name -eq 'PowerShell >= 5') {
                    throw "PowerShell major version is below 5 and cannot be fixed via winget. $($m.Fix)"
                }
                Write-Host "Installing: $($m.Name) -> $($m.Fix)" -ForegroundColor Yellow
                $wingetCmd = Get-Command 'winget' -ErrorAction SilentlyContinue
                if (-not $wingetCmd) {
                    throw "winget is not available on this machine. Install App Installer from the Microsoft Store, then re-run, or install manually: $($m.Fix)"
                }
                Invoke-Expression $m.Fix
                if ($LASTEXITCODE -ne 0) {
                    throw "Install command failed (exit $LASTEXITCODE): $($m.Fix)"
                }
            }

            Write-Step "Re-checking prerequisites"
            $gitCmd = Get-Command 'git' -ErrorAction SilentlyContinue
            $gitOk = [bool]$gitCmd
            $sevenZipCmd = Get-Command '7z.exe' -ErrorAction SilentlyContinue
            $sevenZipOk = [bool]$sevenZipCmd
            if (-not $sevenZipOk) {
                foreach ($loc in @('C:\Program Files\7-Zip\7z.exe', 'C:\Program Files (x86)\7-Zip\7z.exe')) {
                    if (Test-Path $loc) {
                        $folder = Split-Path -Parent $loc
                        $env:PATH = "$folder;$env:PATH"
                        $sevenZipOk = $true
                        break
                    }
                }
            }

            $stillMissing = @()
            if (-not $gitOk) { $stillMissing += 'git' }
            if (-not $sevenZipOk) { $stillMissing += '7z.exe' }
            if ($stillMissing.Count -gt 0) {
                throw "Still missing after install attempt: $($stillMissing -join ', '). Open a new shell (PATH may need a refresh) and re-run this script."
            }
            Write-Host "All prerequisites resolved." -ForegroundColor Green
        } else {
            Write-Host ""
            Write-Host "Missing prerequisites. Run the commands below, then re-run this script," -ForegroundColor Yellow
            Write-Host "or pass -InstallPrereqs to have this script run them for you:" -ForegroundColor Yellow
            foreach ($m in $missing) {
                Write-Host "  $($m.Fix)"
            }
            exit 1
        }
    } else {
        Write-Host "All prerequisites present." -ForegroundColor Green
    }

    # ---------------------------------------------------------------
    # 2. License key
    # ---------------------------------------------------------------
    Write-Step "License key"

    if ($LicenseKey) {
        $newKeyPrefix = $LicenseKey.Substring(0, [Math]::Min(5, $LicenseKey.Length))
        $existingContent = $null
        if (Test-Path $LicenseKeyFile) {
            $existingContent = Get-Content -Path $LicenseKeyFile -Raw -ErrorAction SilentlyContinue
            if ($null -ne $existingContent) { $existingContent = $existingContent.TrimEnd("`r", "`n") }
        }

        if ($null -ne $existingContent -and $existingContent -eq $LicenseKey) {
            Write-Host "server/license.key already contains this key (unchanged)." -ForegroundColor Green
        } elseif ($null -ne $existingContent -and -not $Force) {
            Write-Host "server/license.key already exists with different content; leaving it as-is." -ForegroundColor Yellow
            Write-Host "Pass -Force to overwrite it with the -LicenseKey value." -ForegroundColor Yellow
        } else {
            New-Item -ItemType Directory -Force -Path $ServerDir | Out-Null
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($LicenseKeyFile, $LicenseKey, $utf8NoBom)
            Write-Host "Wrote server/license.key from -LicenseKey argument ($newKeyPrefix..., $($LicenseKey.Length) chars)." -ForegroundColor Green
        }
    } else {
        if ($env:FIVEM_LICENSE_KEY) {
            Write-Host "Using FIVEM_LICENSE_KEY environment variable ($($env:FIVEM_LICENSE_KEY.Substring(0, [Math]::Min(5, $env:FIVEM_LICENSE_KEY.Length)))..., $($env:FIVEM_LICENSE_KEY.Length) chars)." -ForegroundColor Green
        } elseif (Test-Path $LicenseKeyFile) {
            $fileLine = Get-Content -Path $LicenseKeyFile -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -First 1
            if ($fileLine) {
                Write-Host "Using existing server/license.key ($($fileLine.Substring(0, [Math]::Min(5, $fileLine.Length)))..., $($fileLine.Length) chars)." -ForegroundColor Green
            } else {
                throw "No FiveM license key found. Provide one via -LicenseKey <key>, the FIVEM_LICENSE_KEY environment variable, or by creating server\license.key (see server\license.key.example; the file is gitignored and never committed). Get a free key at https://portal.cfx.re"
            }
        } else {
            throw "No FiveM license key found. Provide one via -LicenseKey <key>, the FIVEM_LICENSE_KEY environment variable, or by creating server\license.key (see server\license.key.example; the file is gitignored and never committed). Get a free key at https://portal.cfx.re"
        }
    }

    # ---------------------------------------------------------------
    # 3. Get server
    # ---------------------------------------------------------------
    if ($SkipGetServer) {
        Write-Step "Get server (skipped: -SkipGetServer)"
        if (-not (Test-Path $FxServerExe)) {
            throw "SkipGetServer was set but $FxServerExe does not exist. Remove -SkipGetServer to download it."
        }
        Write-Host "Using existing $FxServerExe" -ForegroundColor Green
    } else {
        Write-Step "Get server (scripts/get-server.ps1)"
        if (-not (Test-Path $GetServerScript)) {
            throw "scripts/get-server.ps1 not found at $GetServerScript"
        }
        $getServerParams = @{}
        if ($ArtifactUrl) { $getServerParams['ArtifactUrl'] = $ArtifactUrl }
        # Baseline it so StrictMode can never see an undefined $LASTEXITCODE,
        # even if a future edit removes an explicit exit from the called script.
        $global:LASTEXITCODE = 0
        & $GetServerScript @getServerParams
        if ($LASTEXITCODE -ne 0) {
            throw "scripts/get-server.ps1 failed with exit code $LASTEXITCODE"
        }
    }

    # ---------------------------------------------------------------
    # 4. Run and check
    # ---------------------------------------------------------------
    Write-Step "Run and check (scripts/restart-and-check.ps1)"
    if (-not (Test-Path $RestartScript)) {
        throw "scripts/restart-and-check.ps1 not found at $RestartScript"
    }
    $restartParams = @{ Seconds = $Seconds }
    if ($KeepRunning) { $restartParams['KeepRunning'] = $true }
    $global:LASTEXITCODE = 0
    & $RestartScript @restartParams
    $checkExitCode = $LASTEXITCODE

    # ---------------------------------------------------------------
    # 5. Verdict
    # ---------------------------------------------------------------
    Write-Step "Verdict"
    $newestLog = Get-NewestLogPath
    $verdict = if ($checkExitCode -eq 0) { 'PASS' } else { 'FAIL' }
    $verdictColor = if ($checkExitCode -eq 0) { 'Green' } else { 'Red' }

    Write-Host ""
    Write-Host "RESULT: $verdict" -ForegroundColor $verdictColor
    if ($newestLog) {
        Write-Host "Log:    $newestLog"
    } else {
        Write-Host "Log:    (none found in $LogsDir)"
    }

    if ($checkExitCode -eq 0) {
        if ($KeepRunning) {
            Write-Host "Next: connect a FiveM client to 127.0.0.1:30120 and run /test_m1"
        } else {
            Write-Host "Next: re-run with -KeepRunning to connect a FiveM client to 127.0.0.1:30120 and run /test_m1"
        }
    } else {
        Write-Host "Next: send the log file above for troubleshooting."
    }

    exit $checkExitCode
} catch {
    Write-Host ""
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    exit 1
}
