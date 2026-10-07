#requires -version 5.1
[CmdletBinding(SupportsShouldProcess=$true)]
param(
    [string]$SiteName = "Default Web Site",
    [string]$ApplicationPath = "/App",
    [string]$ImagesVirtualDirectory = "images",
    [string]$InstallRoot = "$env:ProgramData\InfrastructureHealthBenchmark",
    [switch]$RemoveBenchmarkDataset,
    [switch]$KeepScheduledTask,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

if (-not $PSCmdlet.ShouldProcess($InstallRoot, "Remove diagnostic installation and requested benchmark data")) { return }

if (-not $Force) {
    $answer = Read-Host "Remove Infrastructure Health & Benchmark Diagnostics? Type YES to continue"
    if ($answer -cne "YES") {
        Write-Host "Canceled."
        exit 0
    }
}

$configPath = Join-Path $InstallRoot "config\health.ini"
if (Test-Path -LiteralPath $configPath) {
    . (Join-Path $InstallRoot "Engine\InfrastructureHealth.Common.ps1")
    $config = Read-IniFile -Path $configPath

    if (-not $PSBoundParameters.ContainsKey("SiteName")) {
        $SiteName = [string](Get-IniValue -Config $config -Section "Paths" -Key "SiteName" -Default $SiteName)
    }
    if (-not $PSBoundParameters.ContainsKey("ApplicationPath")) {
        $ApplicationPath = [string](Get-IniValue -Config $config -Section "Paths" -Key "ApplicationPath" -Default $ApplicationPath)
    }
    if (-not $PSBoundParameters.ContainsKey("ImagesVirtualDirectory")) {
        $ImagesVirtualDirectory = [string](Get-IniValue -Config $config -Section "Paths" -Key "ImagesVirtualDirectory" -Default $ImagesVirtualDirectory)
    }
}

$healthPath = $null
$benchmarkPath = $null

try {
    Import-Module WebAdministration -ErrorAction Stop
    $appName = $ApplicationPath.Trim('/')
    $app = Get-WebApplication -Site $SiteName -ErrorAction Stop |
        Where-Object { $_.Path -ieq $ApplicationPath } |
        Select-Object -First 1

    if ($app) {
        $applicationPhysicalPath = [Environment]::ExpandEnvironmentVariables([string]$app.PhysicalPath)
        $healthPath = Join-Path $applicationPhysicalPath "health"

        $vdir = Get-WebVirtualDirectory -Site $SiteName -Application $appName -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -ieq ("/" + $ImagesVirtualDirectory.Trim('/')) } |
            Select-Object -First 1

        if ($vdir) {
            $imagesPath = [Environment]::ExpandEnvironmentVariables([string]$vdir.PhysicalPath)
            $benchmarkPath = Join-Path $imagesPath "__Infrastructure_Health__"
        }
    }
}
catch {
    Write-Warning ("IIS discovery failed during uninstall: {0}" -f $_.Exception.Message)
}

$taskName = "Infrastructure Health & Benchmark Diagnostics"
if (-not $KeepScheduledTask) {
    & schtasks.exe /Delete /TN $taskName /F 2>$null | Out-Null
}
else {
    Write-Warning "Scheduled task retained. Reinstall immediately because its action still points to the Infrastructure Health & Benchmark engine."
}

if ($healthPath -and (Test-Path -LiteralPath $healthPath)) {
    Remove-Item -LiteralPath $healthPath -Recurse -Force
}

if ($RemoveBenchmarkDataset -and $benchmarkPath -and (Test-Path -LiteralPath $benchmarkPath)) {
    Remove-Item -LiteralPath $benchmarkPath -Recurse -Force
}

if (Test-Path -LiteralPath $InstallRoot) {
    Remove-Item -LiteralPath $InstallRoot -Recurse -Force
}

Write-Host "Infrastructure Health & Benchmark Diagnostics removed." -ForegroundColor Green
if ($KeepScheduledTask) {
    Write-Host "Scheduled task was retained, including its existing principal and stored credentials." -ForegroundColor Yellow
}
if (-not $RemoveBenchmarkDataset -and $benchmarkPath) {
    Write-Host "Benchmark dataset was retained: $benchmarkPath"
}
