#requires -version 5.1
<#
.SYNOPSIS
    Builds a portable Infrastructure Health & Benchmark golden reference dataset from a synthetic or authorized reference capture.
.DESCRIPTION
    Extracts benchmark payloads (not anonymized) from a reference capture into a generic reference layout.
    DZI workloads contain only tile pyramids and normalized metadata; source folder names and case UID
    are not retained. File-sequence workloads are copied as generic .bin files so IIS MIME mappings do
    not affect the benchmark.

    Profile SingleField includes only Single Images and Z-stack.
    Profile All includes every supported workload discovered in the source case.
    Profile Auto includes every supported workload discovered in the source case.
.NOTES
    Run in Windows PowerShell 5.1. Source data should be authorized non-sensitive test data.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourceCasePath,
    [string]$OutputPath = (Join-Path $PSScriptRoot "ReferenceDataset"),
    [ValidateSet("Auto", "SingleField", "All")][string]$Profile = "Auto",
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Name, [string]$Result, [ConsoleColor]$Color = [ConsoleColor]::Gray)
    Write-Host ("{0,-36} {1}" -f $Name, $Result) -ForegroundColor $Color
}

function Get-RelativePathSafe {
    param([string]$BasePath, [string]$FullPath)
    $base = (New-Object System.Uri(($BasePath.TrimEnd('\') + '\')))
    $item = New-Object System.Uri($FullPath)
    return [Uri]::UnescapeDataString($base.MakeRelativeUri($item).ToString()).Replace('/', '\')
}

function Get-DziDescriptor {
    param([string]$Root)

    $candidates = @()
    $candidates += @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.dzi -ErrorAction SilentlyContinue)
    $candidates += @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter *.xml -ErrorAction SilentlyContinue)

    foreach ($file in $candidates) {
        try {
            $text = [IO.File]::ReadAllText($file.FullName)
            if ($text -notmatch '<Image\s') { continue }
            [xml]$xml = $text
            $image = $xml.DocumentElement
            $size = $image.SelectSingleNode("*[local-name()='Size']")
            if (-not $image -or -not $size) { continue }
            return [pscustomobject]@{
                File = $file.FullName
                TileSize = [int]$image.GetAttribute("TileSize")
                Overlap = [int]$image.GetAttribute("Overlap")
                Format = [string]$image.GetAttribute("Format")
                Width = [int]$size.GetAttribute("Width")
                Height = [int]$size.GetAttribute("Height")
            }
        }
        catch {
            # Continue scanning candidates.
        }
    }
    return $null
}

function Get-DziTileRoot {
    param([string]$Root, [int]$ExpectedMaxLevel)

    $numericDirs = @(Get-ChildItem -LiteralPath $Root -Recurse -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+$' })

    foreach ($dir in ($numericDirs | Sort-Object FullName)) {
        if ([int]$dir.Name -ne $ExpectedMaxLevel) { continue }
        $png = Get-ChildItem -LiteralPath $dir.FullName -File -Filter *.png -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $png) { continue }
        $parent = Split-Path -Parent $dir.FullName
        $levelCount = @(Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+$' }).Count
        if ($levelCount -ge 8) { return $parent }
    }
    return $null
}

function Copy-DziPayload {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string]$RelativeUrlRoot,
        [string]$Name
    )

    $descriptor = Get-DziDescriptor -Root $SourceRoot
    if (-not $descriptor) { throw "No DZI descriptor found below '$SourceRoot'." }

    $maxDimension = [Math]::Max($descriptor.Width, $descriptor.Height)
    $maxLevel = [int][Math]::Ceiling([Math]::Log($maxDimension, 2))
    $tileRoot = Get-DziTileRoot -Root $SourceRoot -ExpectedMaxLevel $maxLevel
    if (-not $tileRoot) { throw "No DZI tile pyramid matching max level $maxLevel found below '$SourceRoot'." }

    $destTiles = Join-Path $DestinationRoot "tiles"
    if (Test-Path -LiteralPath $DestinationRoot) { Remove-Item -LiteralPath $DestinationRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $destTiles -Force | Out-Null
    Copy-Item -Path (Join-Path $tileRoot '*') -Destination $destTiles -Recurse -Force

    $files = @(Get-ChildItem -LiteralPath $destTiles -Recurse -File)
    $bytes = [int64](($files | Measure-Object -Property Length -Sum).Sum)

    return [ordered]@{
        name = $Name
        width = $descriptor.Width
        height = $descriptor.Height
        tileSize = $descriptor.TileSize
        overlap = $descriptor.Overlap
        format = $descriptor.Format
        minLevel = 0
        maxLevel = $maxLevel
        tileBaseUrl = ($RelativeUrlRoot.TrimEnd('/') + '/tiles')
        fileCount = $files.Count
        totalBytes = $bytes
    }
}

function Get-PayloadFiles {
    param([string]$Root)

    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction Stop |
        Where-Object {
            $_.Length -ge 65536 -and
            $_.Name -notmatch '^(preview|thumb)\.(png|jpg|jpeg)$' -and
            $_.Extension -notin @('.json', '.xml', '.dat')
        } |
        Sort-Object FullName)

    if (-not $files.Count) {
        $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction Stop |
            Where-Object { $_.Length -ge 65536 } |
            Sort-Object FullName)
    }
    return $files
}

function Copy-FileSequencePayload {
    param(
        [string]$SourceRoot,
        [string]$DestinationRoot,
        [string]$RelativeUrlRoot,
        [string]$Name,
        [int]$MaxFiles = 256
    )

    $sourceFiles = @(Get-PayloadFiles -Root $SourceRoot | Select-Object -First $MaxFiles)
    if (-not $sourceFiles.Count) { throw "No benchmark payload files found below '$SourceRoot'." }

    if (Test-Path -LiteralPath $DestinationRoot) { Remove-Item -LiteralPath $DestinationRoot -Recurse -Force }
    $destFiles = Join-Path $DestinationRoot "files"
    New-Item -ItemType Directory -Path $destFiles -Force | Out-Null

    $urls = @()
    $lengths = @()
    $index = 0
    foreach ($file in $sourceFiles) {
        $index++
        $fileName = ('{0:D4}.bin' -f $index)
        $target = Join-Path $destFiles $fileName
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        $urls += ($RelativeUrlRoot.TrimEnd('/') + '/files/' + $fileName)
        $lengths += [int64]$file.Length
    }

    return [ordered]@{
        name = $Name
        files = $urls
        sourceFileCount = $sourceFiles.Count
        totalBytes = [int64](($lengths | Measure-Object -Sum).Sum)
        averageBytes = [int64][Math]::Round((($lengths | Measure-Object -Average).Average), 0)
    }
}

function Get-TemplateSelection {
    param([string]$SelectedProfile)

    $definitionPath = Join-Path $PSScriptRoot "Web\workloads\templates.json"
    if (-not (Test-Path -LiteralPath $definitionPath)) {
        throw "Workload definition file not found: $definitionPath"
    }
    $definitions = ([IO.File]::ReadAllText($definitionPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop)
    $ids = @()
    foreach ($template in @($definitions.templates)) {
        if ($SelectedProfile -eq 'Auto') {
            $ids += [string]$template.id
            continue
        }
        $profiles = @($template.profiles | ForEach-Object { [string]$_ })
        if ($profiles -contains $SelectedProfile) {
            $ids += [string]$template.id
        }
    }
    return $ids
}

if (-not (Test-Path -LiteralPath $SourceCasePath)) {
    throw "Source case path does not exist: $SourceCasePath"
}

$SourceCasePath = (Resolve-Path -LiteralPath $SourceCasePath).Path
$OutputPath = [IO.Path]::GetFullPath($OutputPath)
$sourceFull = [IO.Path]::GetFullPath($SourceCasePath).TrimEnd('\','/')
$outputFull = [IO.Path]::GetFullPath($OutputPath).TrimEnd('\','/')
if ($sourceFull -eq $outputFull -or $sourceFull.StartsWith($outputFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or $outputFull.StartsWith($sourceFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Source and output directories must be separate and must not contain each other.'
}
if ((Test-Path -LiteralPath $OutputPath) -and $Force) {
    Remove-Item -LiteralPath $OutputPath -Recurse -Force
}
elseif (Test-Path -LiteralPath (Join-Path $OutputPath 'reference.json')) {
    throw "Reference dataset already exists at '$OutputPath'. Use -Force to replace it."
}
New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Infrastructure Health & Benchmark Golden Reference Dataset" -ForegroundColor Cyan
Write-Host " Prepare - v0.1.8" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Step "Source case" $SourceCasePath Green
Write-Step "Profile" $Profile Green

$dirs = @(Get-ChildItem -LiteralPath $SourceCasePath -Directory -ErrorAction Stop)
$singleDir = $dirs | Where-Object { $_.Name -eq 'single-images' -or $_.Name -like 'Confocal Images#*' } | Select-Object -First 1
$stackDir = $dirs | Where-Object { $_.Name -eq 'z-stack' -or $_.Name -like 'VivaStack#*' } | Select-Object -First 1
$blockDir = $dirs | Where-Object { $_.Name -like 'xy-mosaic*' -or $_.Name -like 'VivaBlock#*' } | Select-Object -First 1
$cubeDir = $dirs | Where-Object { $_.Name -eq 'volume' -or $_.Name -like 'VivaCube#*' } | Select-Object -First 1

$requested = Get-TemplateSelection -SelectedProfile $Profile
$templates = [ordered]@{}

if ($requested -contains 'single-images' -and $singleDir) {
    try {
        $templates['single-images'] = [ordered]@{
            available = $true
            kind = 'file-sequence'
            source = Copy-FileSequencePayload -SourceRoot $singleDir.FullName -DestinationRoot (Join-Path $OutputPath 'single-images') -RelativeUrlRoot 'reference/single-images' -Name 'Single Images'
        }
        Write-Step "Single Images workload" ("PASS ({0} files)" -f $templates['single-images'].source.sourceFileCount) Green
    } catch { Write-Step "Single Images workload" ("WARN ({0})" -f $_.Exception.Message) Yellow }
}

if ($requested -contains 'z-stack' -and $stackDir) {
    try {
        $templates['z-stack'] = [ordered]@{
            available = $true
            kind = 'file-sequence'
            source = Copy-FileSequencePayload -SourceRoot $stackDir.FullName -DestinationRoot (Join-Path $OutputPath 'z-stack') -RelativeUrlRoot 'reference/z-stack' -Name 'Z-stack'
        }
        Write-Step "Z-stack workload" ("PASS ({0} files)" -f $templates['z-stack'].source.sourceFileCount) Green
    } catch { Write-Step "Z-stack workload" ("WARN ({0})" -f $_.Exception.Message) Yellow }
}

if ($requested -contains 'xy-mosaic' -and $blockDir) {
    try {
        $templates['xy-mosaic'] = [ordered]@{
            available = $true
            kind = 'dzi-navigation'
            sources = @(
                (Copy-DziPayload -SourceRoot $blockDir.FullName -DestinationRoot (Join-Path $OutputPath 'xy-mosaic\block1') -RelativeUrlRoot 'reference/xy-mosaic/block1' -Name 'XY Mosaic 1')
            )
        }
        Write-Step "XY Mosaic workload" ("PASS ({0} x {1})" -f $templates['xy-mosaic'].sources[0].width, $templates['xy-mosaic'].sources[0].height) Green
    } catch { Write-Step "XY Mosaic workload" ("WARN ({0})" -f $_.Exception.Message) Yellow }
}

if ($requested -contains 'volume' -and $cubeDir) {
    try {
        $cubeBlocks = @(Get-ChildItem -LiteralPath $cubeDir.FullName -Directory -ErrorAction Stop |
            Where-Object { $_.Name -like 'xy-mosaic*' -or $_.Name -like 'VivaBlock#*' } |
            Sort-Object Name |
            Select-Object -First 3)
        if ($cubeBlocks.Count -lt 3) { throw "Volume did not contain three XY Mosaic directories." }
        $cubeSources = @()
        for ($i = 0; $i -lt $cubeBlocks.Count; $i++) {
            $cubeSources += (Copy-DziPayload -SourceRoot $cubeBlocks[$i].FullName -DestinationRoot (Join-Path $OutputPath ('volume\block{0}' -f ($i + 1))) -RelativeUrlRoot ('reference/volume/block{0}' -f ($i + 1)) -Name ('Volume block {0}' -f ($i + 1)))
        }
        $templates['volume'] = [ordered]@{
            available = $true
            kind = 'dzi-series'
            sources = $cubeSources
        }
        Write-Step "Volume workload" ("PASS ({0} DZI planes)" -f $cubeSources.Count) Green
    } catch { Write-Step "Volume workload" ("WARN ({0})" -f $_.Exception.Message) Yellow }
}

$availableIds = @($templates.Keys)
if (-not $availableIds.Count) {
    throw "No supported benchmark workloads could be prepared from the source case."
}

# Build a canonical SHA-256 manifest over the prepared payload. The catalog itself
# is excluded so the dataset hash remains stable when metadata fields are extended.
$hashLines = @()
$payloadFiles = @(Get-ChildItem -LiteralPath $OutputPath -Recurse -File -ErrorAction Stop |
    Where-Object { $_.Name -notin @('reference.json', 'files.sha256', 'README.txt') } |
    Sort-Object FullName)
$totalPreparedBytes = [int64]0
foreach ($file in $payloadFiles) {
    $relative = Get-RelativePathSafe -BasePath $OutputPath -FullPath $file.FullName
    $relative = $relative.Replace('\', '/')
    $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $hashLines += ("{0} *{1}" -f $hash, $relative)
    $totalPreparedBytes += [int64]$file.Length
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$hashText = ($hashLines -join "`n") + "`n"
[IO.File]::WriteAllText((Join-Path $OutputPath 'files.sha256'), $hashText, $utf8NoBom)
$sha = [Security.Cryptography.SHA256]::Create()
try {
    $datasetHash = ([BitConverter]::ToString($sha.ComputeHash($utf8NoBom.GetBytes($hashText)))).Replace('-', '').ToLowerInvariant()
}
finally { $sha.Dispose() }

$reference = [ordered]@{
    schemaVersion = 1
    referenceVersion = '1.0'
    product = 'Infrastructure Health & Benchmark Golden Reference Dataset'
    source = 'synthetic or authorized reference'
    preparedAt = (Get-Date).ToString('o')
    profile = $Profile
    enabledTemplates = $availableIds
    payloadFileCount = $payloadFiles.Count
    payloadBytes = $totalPreparedBytes
    datasetSha256 = $datasetHash
    templates = $templates
}

$referenceJson = $reference | ConvertTo-Json -Depth 12
[IO.File]::WriteAllText((Join-Path $OutputPath 'reference.json'), $referenceJson, $utf8NoBom)

Write-Step "Reference catalog" ("PASS ({0})" -f ($availableIds -join ', ')) Green
Write-Step "Payload manifest" ("PASS ({0} files / SHA-256 {1})" -f $payloadFiles.Count, $datasetHash) Green
Write-Host ""
Write-Host "Reference dataset prepared:" -ForegroundColor Cyan
Write-Host $OutputPath
Write-Host ""
Write-Host "To install it on a Application server:" -ForegroundColor Cyan
Write-Host ('  .\Import-InfrastructureHealthReferenceDataset.ps1 -SourcePath "{0}"' -f $OutputPath)
