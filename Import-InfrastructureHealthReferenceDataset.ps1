#requires -version 5.1
<#+
.SYNOPSIS
    Installs a prepared Infrastructure Health & Benchmark reference dataset into the configured /images storage.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$SourcePath,
    [string]$SiteName = 'Default Web Site',
    [string]$ApplicationPath = '/App',
    [string]$ImagesVirtualDirectory = 'images',
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) { throw 'Administrator privileges are required.' }
if (-not (Test-Path -LiteralPath (Join-Path $SourcePath 'reference.json'))) {
    throw "Prepared reference.json was not found below: $SourcePath"
}

Import-Module WebAdministration -ErrorAction Stop
$appName = $ApplicationPath.Trim('/')
$vdir = Get-WebVirtualDirectory -Site $SiteName -Application $appName -ErrorAction Stop |
    Where-Object { $_.Path -ieq ('/' + $ImagesVirtualDirectory.Trim('/')) } |
    Select-Object -First 1
if (-not $vdir) { throw "IIS virtual directory '$ImagesVirtualDirectory' was not found." }

$imagesPath = [Environment]::ExpandEnvironmentVariables([string]$vdir.PhysicalPath)
$target = Join-Path $imagesPath '__Infrastructure_Health__\reference'

if ((Test-Path -LiteralPath $target) -and $Force) {
    Remove-Item -LiteralPath $target -Recurse -Force
}
New-Item -ItemType Directory -Path $target -Force | Out-Null
Copy-Item -Path (Join-Path $SourcePath '*') -Destination $target -Recurse -Force

Write-Host ('Reference dataset installed: {0}' -f $target) -ForegroundColor Green
Write-Host ('Catalog URL: {0}/images/__Infrastructure_Health__/reference/reference.json' -f $ApplicationPath.TrimEnd('/')) -ForegroundColor Cyan
