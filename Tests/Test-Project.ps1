#requires -version 5.1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1') {
    $tokens = $null; $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
}
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $root 'Web') -Recurse -File -Filter '*.json') {
    Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json | Out-Null
}
. (Join-Path $root 'Engine/InfrastructureHealth.Common.ps1')
$config = Read-IniFile (Join-Path $root 'config/health.ini')
if ((Get-IniValue $config 'Paths' 'ApplicationPath') -ne '/App') { throw 'Unexpected application default.' }
if ((Get-IniValue $config 'Diagnostics' 'DsnName') -ne 'HealthCheck') { throw 'Unexpected DSN default.' }
if ((Get-IniValue $config 'Health' 'Version') -ne '0.1.8') { throw 'Version mismatch.' }
'PowerShell parsing, JSON and generic configuration checks passed. No installation performed.'
