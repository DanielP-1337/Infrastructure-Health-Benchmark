#requires -version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('ihb-reference-test-' + [guid]::NewGuid().ToString('N'))
try {
    $source = Join-Path $temp 'capture'
    foreach ($name in 'single-images','z-stack') {
        $dir = Join-Path $source $name
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        foreach ($i in 1..3) { [IO.File]::WriteAllBytes((Join-Path $dir "$i.bin"), (New-Object byte[] 70000)) }
    }
    Copy-Item -LiteralPath (Join-Path $root 'TestDataset') -Destination (Join-Path $source 'xy-mosaic') -Recurse
    New-Item -ItemType Directory -Path (Join-Path $source 'volume') -Force | Out-Null
    foreach ($i in 1..3) { Copy-Item -LiteralPath (Join-Path $root 'TestDataset') -Destination (Join-Path $source "volume/xy-mosaic-$i") -Recurse }
    $output = Join-Path $temp 'prepared'
    & (Join-Path $root 'Prepare-InfrastructureHealthReferenceDataset.ps1') -SourceCasePath $source -OutputPath $output
    $catalog = Get-Content -LiteralPath (Join-Path $output 'reference.json') -Raw | ConvertFrom-Json
    if (($catalog.enabledTemplates | Sort-Object) -join ',' -ne 'single-images,volume,xy-mosaic,z-stack') { throw 'Expected all four generic workloads.' }
    if ($catalog.templates.volume.sources.Count -ne 3) { throw 'Expected three volume planes.' }
    foreach ($name in 'single-images','z-stack') {
        if ($catalog.templates.$name.source.files.Count -ne 3) { throw 'Expected three sequence files.' }
    }
    $guarded = $false
    try { & (Join-Path $root 'Prepare-InfrastructureHealthReferenceDataset.ps1') -SourceCasePath $source -OutputPath $source -Force } catch { $guarded = $true }
    if (-not $guarded -or -not (Test-Path (Join-Path $source 'xy-mosaic/benchmark.dzi'))) { throw 'Source preservation guard failed.' }
    'Synthetic reference preparation and source preservation checks passed.'
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
}
