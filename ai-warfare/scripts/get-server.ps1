<#
.SYNOPSIS
    Downloads the latest recommended FXServer Windows artifact and clones
    cfx-server-data, laying out server/artifact/ and server/data/.

.DESCRIPTION
    Run this on the Windows PC that will actually host the server (this
    script cannot be executed or verified in the dev container that wrote
    it — see README.md "Verified vs. unverified").

    Steps:
      1. Fetch https://runtime.fivem.net/artifacts/fivem/build_server_windows/master/
         and try to find the "LATEST RECOMMENDED" build's server.7z / server.zip URL.
      2. If that parse fails (the listing page is a plain directory-style HTML
         page whose exact markup is UNVERIFIED from this environment — it was
         never fetched here because runtime.fivem.net is unreachable from the
         container that authored this script), stop and tell the user to pass
         -ArtifactUrl explicitly, found by opening that page in a browser and
         copying the "LATEST RECOMMENDED" link.
      3. Download and extract the archive into server/artifact/.
      4. Clone https://github.com/citizenfx/cfx-server-data into server/data/
         (requires git on PATH).
      5. Copy the standard resource set (mapmanager, chat, spawnmanager,
         sessionmanager, basic-gamemode, hardcap) from server/data/resources/
         into resources/ at the repo root, alongside resources/[mission]/,
         so a single resources/ folder works for FXServer. See server/server.cfg
         header and README.md for why this layout was chosen.

.PARAMETER ArtifactUrl
    Optional. Direct URL to a server.7z/server.zip build. Use this if the
    automatic parse of the artifacts listing page fails.

.PARAMETER SkipData
    Optional switch. Skip the cfx-server-data clone/copy step (e.g. if you
    already have it and just want a fresh server artifact).

.NOTES
    PowerShell 5.1 compatible. Requires: Internet access, git (for step 4),
    and either 7-Zip (7z.exe on PATH) for .7z or built-in Expand-Archive
    for .zip.
#>

[CmdletBinding()]
param(
    [string]$ArtifactUrl,
    [switch]$SkipData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ServerDir  = Join-Path $RepoRoot 'server'
$ArtifactDir = Join-Path $ServerDir 'artifact'
$DataDir    = Join-Path $ServerDir 'data'
$ResourcesDir = Join-Path $RepoRoot 'resources'
$ListingUrl = 'https://runtime.fivem.net/artifacts/fivem/build_server_windows/master/'

function Write-Step($msg) {
    Write-Host "==> $msg" -ForegroundColor Cyan
}

function Resolve-ArtifactUrl {
    param([string]$Listing)

    Write-Step "Fetching artifact listing: $Listing"
    # UNVERIFIED: the exact HTML structure of this listing page has not been
    # observed from this environment (runtime.fivem.net returns 403 through
    # the dev-container proxy). This regex targets the commonly-documented
    # pattern where the "LATEST RECOMMENDED" build links to a numbered build
    # folder containing server.7z, e.g.:
    #   <a href="/artifacts/fivem/build_server_windows/master/1234-abcdef/">...LATEST RECOMMENDED...</a>
    # If FiveM changes this markup, the regex below will simply fail to
    # match and this function returns $null, triggering the -ArtifactUrl
    # guidance message below.
    try {
        $resp = Invoke-WebRequest -Uri $Listing -UseBasicParsing
    } catch {
        Write-Warning "Could not fetch $Listing : $($_.Exception.Message)"
        return $null
    }

    $html = $resp.Content

    # Look for a build folder link near the text "RECOMMENDED".
    $recommendedMatch = [regex]::Match(
        $html,
        '<a[^>]+href="(?<href>[^"]+)"[^>]*>[^<]*RECOMMENDED[^<]*</a>',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $recommendedMatch.Success) {
        Write-Warning "Could not find a 'LATEST RECOMMENDED' link in the listing page."
        return $null
    }

    $buildHref = $recommendedMatch.Groups['href'].Value
    if ($buildHref -notmatch '^https?://') {
        $buildHref = ($Listing.TrimEnd('/')) + '/' + $buildHref.TrimStart('/')
    }
    if (-not $buildHref.EndsWith('/')) { $buildHref += '/' }

    Write-Step "Recommended build folder: $buildHref"

    try {
        $buildResp = Invoke-WebRequest -Uri $buildHref -UseBasicParsing
    } catch {
        Write-Warning "Could not fetch build folder $buildHref : $($_.Exception.Message)"
        return $null
    }

    $archiveMatch = [regex]::Match(
        $buildResp.Content,
        '<a[^>]+href="(?<href>[^"]*server\.(7z|zip))"',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if (-not $archiveMatch.Success) {
        Write-Warning "Could not find server.7z / server.zip in $buildHref"
        return $null
    }

    $archiveHref = $archiveMatch.Groups['href'].Value
    if ($archiveHref -notmatch '^https?://') {
        $archiveHref = $buildHref.TrimEnd('/') + '/' + $archiveHref.TrimStart('/')
    }
    return $archiveHref
}

try {
    if (-not $ArtifactUrl) {
        $ArtifactUrl = Resolve-ArtifactUrl -Listing $ListingUrl
    }

    if (-not $ArtifactUrl) {
        Write-Host ""
        Write-Host "Automatic artifact discovery failed." -ForegroundColor Yellow
        Write-Host "Open this URL in a browser:" -ForegroundColor Yellow
        Write-Host "  $ListingUrl"
        Write-Host "Find the 'LATEST RECOMMENDED' build, open its folder, copy the"
        Write-Host "server.7z (or server.zip) link, and re-run this script as:"
        Write-Host "  .\get-server.ps1 -ArtifactUrl <that-url>"
        exit 1
    }

    Write-Step "Using artifact URL: $ArtifactUrl"

    New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null
    $fileName = Split-Path -Leaf ([Uri]$ArtifactUrl).AbsolutePath
    $downloadPath = Join-Path $env:TEMP $fileName

    Write-Step "Downloading to $downloadPath"
    Invoke-WebRequest -Uri $ArtifactUrl -OutFile $downloadPath -UseBasicParsing

    Write-Step "Extracting into $ArtifactDir"
    if ($fileName -like '*.zip') {
        Expand-Archive -Path $downloadPath -DestinationPath $ArtifactDir -Force
    } elseif ($fileName -like '*.7z') {
        $sevenZip = Get-Command '7z.exe' -ErrorAction SilentlyContinue
        if (-not $sevenZip) {
            throw "7z.exe not found on PATH. Install 7-Zip (https://www.7-zip.org/) and ensure 7z.exe is on PATH, then re-run, or download a .zip build instead via -ArtifactUrl."
        }
        & $sevenZip.Source x $downloadPath -o"$ArtifactDir" -y | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "7z.exe extraction failed with exit code $LASTEXITCODE"
        }
    } else {
        throw "Unrecognized artifact extension for '$fileName' (expected .zip or .7z)"
    }

    Write-Step "Artifact extracted to $ArtifactDir"

    if (-not $SkipData) {
        $gitCmd = Get-Command 'git' -ErrorAction SilentlyContinue
        if (-not $gitCmd) {
            throw "git not found on PATH. Install Git for Windows (https://git-scm.com/download/win) and re-run, or pass -SkipData if server/data/ already exists."
        }
        Write-Step "git version: $(git --version)"

        if (Test-Path $DataDir) {
            Write-Warning "$DataDir already exists; skipping clone. Delete it first to re-clone."
        } else {
            Write-Step "Cloning cfx-server-data into $DataDir"
            git clone --depth 1 https://github.com/citizenfx/cfx-server-data.git $DataDir
            if ($LASTEXITCODE -ne 0) {
                throw "git clone failed with exit code $LASTEXITCODE"
            }
        }

        # Copy the standard resource set into the repo-root resources/ folder,
        # alongside resources/[mission]/, WITHOUT touching resources/[mission]/.
        # See server/server.cfg header for why FXServer needs a single
        # resources/ directory at the repo root.
        $standardResources = @('mapmanager', 'chat', 'spawnmanager', 'sessionmanager', 'basic-gamemode', 'hardcap')
        New-Item -ItemType Directory -Force -Path $ResourcesDir | Out-Null

        foreach ($resName in $standardResources) {
            $found = Get-ChildItem -Path (Join-Path $DataDir 'resources') -Recurse -Directory -Filter $resName -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $found) {
                Write-Warning "Could not find '$resName' under $DataDir\resources — check the cfx-server-data layout manually."
                continue
            }
            $dest = Join-Path $ResourcesDir $resName
            Write-Step "Copying $resName -> $dest"
            Copy-Item -Path $found.FullName -Destination $dest -Recurse -Force
        }
    }

    Write-Host ""
    Write-Host "Done." -ForegroundColor Green
    Write-Host "Artifact: $ArtifactDir"
    Write-Host "Data:     $DataDir"
    Write-Host "Next: provide a license key, then run scripts\restart-and-check.ps1"
    Write-Host "      either set `$env:FIVEM_LICENSE_KEY = '<key>'"
    Write-Host "      or create server\license.key containing just the key (gitignored)"
    exit 0
} catch {
    Write-Host ""
    Write-Host "FAILED: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    exit 1
}
