#requires -version 5.1
<#
.SYNOPSIS
    Downloads the pinned OpenSeadragon runtime into this deployment package.
.DESCRIPTION
    Run once on an internet-connected Windows machine to make the package fully
    self-contained for offline Infrastructure Health & Benchmark installation or upgrade.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$Version = "6.1.0"
$ReleaseUrl = "https://github.com/openseadragon/openseadragon/releases/download/v6.1.0/openseadragon-bin-6.1.0.zip"
$ReleaseSha256 = "acfa8c00ed93731d2a7dd02a0466a810d15adf4423189563f22e22f574b3ef77"
$TargetDir = Join-Path $PSScriptRoot ("Web\vendor\openseadragon\" + $Version)
$TargetFile = Join-Path $TargetDir "openseadragon.min.js"

function Test-OpenSeadragonVersion {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    $header = (Get-Content -LiteralPath $Path -TotalCount 8 -ErrorAction Stop) -join "`n"
    return ($header -match ("openseadragon\s+" + [Regex]::Escape($Version)))
}

if (Test-OpenSeadragonVersion -Path $TargetFile) {
    Write-Host "OpenSeadragon $Version is already vendored:" -ForegroundColor Green
    Write-Host "  $TargetFile"
    exit 0
}

$tempRoot = Join-Path $env:TEMP ("InfrastructureHealth-OSD-" + [Guid]::NewGuid().ToString("N"))
$zipPath = Join-Path $tempRoot "openseadragon.zip"
$extractPath = Join-Path $tempRoot "extract"

try {
    New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host "Downloading OpenSeadragon $Version..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $ReleaseUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 60
    $downloadHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($downloadHash -ne $ReleaseSha256) {
        throw "OpenSeadragon release archive SHA-256 mismatch. Expected $ReleaseSha256, got $downloadHash."
    }
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

    $source = Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter "openseadragon.min.js" -ErrorAction Stop |
        Select-Object -First 1
    if (-not $source) {
        throw "OpenSeadragon release archive did not contain openseadragon.min.js."
    }

    if (-not (Test-OpenSeadragonVersion -Path $source.FullName)) {
        throw "Downloaded runtime does not report OpenSeadragon $Version."
    }

    Copy-Item -LiteralPath $source.FullName -Destination $TargetFile -Force
    Write-Host "Vendored OpenSeadragon $Version successfully:" -ForegroundColor Green
    Write-Host "  $TargetFile"
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
