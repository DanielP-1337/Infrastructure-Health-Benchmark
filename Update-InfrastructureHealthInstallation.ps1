#requires -version 5.1
<#
.SYNOPSIS
    Upgrades an existing Infrastructure Health & Benchmark installation in place.
.DESCRIPTION
    This wrapper calls Install-InfrastructureHealth.ps1. Existing scheduled task
    credentials, principal, trigger, and settings are preserved by the installer.
#>
[CmdletBinding()]
param(
    [string]$SiteName = "Default Web Site",
    [string]$ApplicationPath = "/App",
    [string]$ImagesVirtualDirectory = "images",
    [string]$InstallRoot = "$env:ProgramData\InfrastructureHealthBenchmark",
    [switch]$SkipBenchmarkDataset,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$installer = Join-Path $PSScriptRoot "Install-InfrastructureHealth.ps1"
$arguments = @{
    InstallRoot = $InstallRoot
}

if ($PSBoundParameters.ContainsKey("SiteName")) {
    $arguments.SiteName = $SiteName
}
if ($PSBoundParameters.ContainsKey("ApplicationPath")) {
    $arguments.ApplicationPath = $ApplicationPath
}
if ($PSBoundParameters.ContainsKey("ImagesVirtualDirectory")) {
    $arguments.ImagesVirtualDirectory = $ImagesVirtualDirectory
}
if ($SkipBenchmarkDataset) {
    $arguments.SkipBenchmarkDataset = $true
}
if ($Force) {
    $arguments.Force = $true
}

& $installer @arguments
exit 0
