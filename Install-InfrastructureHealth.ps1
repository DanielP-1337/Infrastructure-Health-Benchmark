#requires -version 5.1
<#
.SYNOPSIS
    Installs or upgrades Infrastructure Health & Benchmark.
.DESCRIPTION
    Deploys the static IIS dashboard, PowerShell 5.1 diagnostic worker, scheduled
    health task, HTTP benchmark files, and synthetic DZI benchmark dataset.

    Existing managed installations are upgraded in place. If the scheduled task
    already exists, its principal, stored credentials, trigger, and settings are
    preserved. The task is disabled only for the duration of the file update and
    is then restored to its previous enabled/disabled state.
.NOTES
    Run from an elevated Windows PowerShell 5.1 console on the Application IIS server.
    Comments and runtime output are English-USA and ASCII-safe.
#>
[CmdletBinding()]
param(
    [string]$SiteName = "Default Web Site",
    [string]$ApplicationPath = "/App",
    [string]$ImagesVirtualDirectory = "images",
    [string]$ApplicationPhysicalPath,
    [string]$ImagesPhysicalPath,
    [string]$InstallRoot = "$env:ProgramData\InfrastructureHealthBenchmark",
    [switch]$SkipBenchmarkDataset,
    [switch]$Force
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "Engine\InfrastructureHealth.Common.ps1")

$ProductVersion = "0.1.8"
$TaskName = "Infrastructure Health & Benchmark Diagnostics"
$ImageBenchmarkSubdirectory = "__Infrastructure_Health__"
$DziSubdirectory = "dzi"
$PinnedOpenSeadragonVersion = "6.1.0"
$PinnedOpenSeadragonReleaseUrl = "https://github.com/openseadragon/openseadragon/releases/download/v6.1.0/openseadragon-bin-6.1.0.zip"
$PinnedOpenSeadragonReleaseSha256 = "acfa8c00ed93731d2a7dd02a0466a810d15adf4423189563f22e22f574b3ef77"

function Write-Step {
    param(
        [string]$Name,
        [string]$Result,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    Write-Host ("{0,-44} {1}" -f $Name, $Result) -ForegroundColor $Color
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Expand-PathValue {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }
    return [Environment]::ExpandEnvironmentVariables($Value)
}

function New-RandomFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][int64]$SizeBytes
    )

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $buffer = New-Object byte[] (1MB)
    $rng.GetBytes($buffer)
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

    try {
        $remaining = $SizeBytes
        while ($remaining -gt 0) {
            $count = [int][Math]::Min($buffer.Length, $remaining)
            $stream.Write($buffer, 0, $count)
            $remaining -= $count
        }
        $stream.Flush()
    }
    finally {
        $stream.Dispose()
        $rng.Dispose()
    }
}

function Ensure-RandomFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][int64]$SizeBytes
    )

    if (Test-Path -LiteralPath $Path) {
        try {
            $existing = Get-Item -LiteralPath $Path -ErrorAction Stop
            if ($existing.Length -eq $SizeBytes) {
                return
            }
        }
        catch {
            # Recreate the file below.
        }
    }

    New-RandomFile -Path $Path -SizeBytes $SizeBytes
}

function Get-ExistingConfigValue {
    param(
        $Config,
        [string]$Section,
        [string]$Key,
        $Default
    )

    if ($null -ne $Config -and $Config.ContainsKey($Section) -and $Config[$Section].ContainsKey($Key)) {
        return $Config[$Section][$Key]
    }
    return $Default
}


function Get-DziFrameworkSummary {
    param([Parameter(Mandatory=$true)][string]$DziPath)

    $result = [ordered]@{
        available = $false
        framework = "None"
        path = $null
    }

    if (-not (Test-Path -LiteralPath $DziPath)) {
        return $result
    }

    $result.available = $true
    $legacy = Join-Path $DziPath "seadragon\src"
    $legacyOk = (
        (Test-Path -LiteralPath (Join-Path $legacy "Seadragon.Core.js")) -and
        (Test-Path -LiteralPath (Join-Path $legacy "Seadragon.DeepZoom.js")) -and
        (Test-Path -LiteralPath (Join-Path $legacy "Seadragon.TileSource.js")) -and
        (Test-Path -LiteralPath (Join-Path $legacy "Seadragon.Viewer.js"))
    )

    $modern = Get-ChildItem -LiteralPath $DziPath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^openseadragon(\.min)?\.js$' } |
        Select-Object -First 1

    if ($legacyOk -and $modern) {
        $result.framework = "Legacy Seadragon + OpenSeadragon"
        $result.path = $legacy
    }
    elseif ($legacyOk) {
        $result.framework = "Legacy Seadragon"
        $result.path = $legacy
    }
    elseif ($modern) {
        $result.framework = "OpenSeadragon"
        $result.path = $modern.FullName
    }
    else {
        $result.framework = "Unknown DZI viewer"
        $result.path = $DziPath
    }

    return $result
}

function Test-PinnedOpenSeadragonFile {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Version
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        $header = (Get-Content -LiteralPath $Path -TotalCount 8 -ErrorAction Stop) -join "`n"
        return ($header -match ("openseadragon\s+" + [Regex]::Escape($Version)))
    }
    catch {
        return $false
    }
}

function Install-PinnedOpenSeadragonVendor {
    param(
        [Parameter(Mandatory=$true)][string]$HealthPath,
        [AllowNull()][string]$PreservedVendorFile
    )

    $vendorDir = Join-Path $HealthPath ("vendor\openseadragon\" + $PinnedOpenSeadragonVersion)
    $target = Join-Path $vendorDir "openseadragon.min.js"
    New-Item -ItemType Directory -Path $vendorDir -Force | Out-Null

    $packaged = Join-Path $PSScriptRoot ("Web\vendor\openseadragon\" + $PinnedOpenSeadragonVersion + "\openseadragon.min.js")
    if (Test-PinnedOpenSeadragonFile -Path $packaged -Version $PinnedOpenSeadragonVersion) {
        Copy-Item -LiteralPath $packaged -Destination $target -Force
        return [pscustomobject]@{ Available=$true; Source="packaged"; Path=$target; Error=$null }
    }

    if ($PreservedVendorFile -and (Test-PinnedOpenSeadragonFile -Path $PreservedVendorFile -Version $PinnedOpenSeadragonVersion)) {
        Copy-Item -LiteralPath $PreservedVendorFile -Destination $target -Force
        return [pscustomobject]@{ Available=$true; Source="preserved from existing installation"; Path=$target; Error=$null }
    }

    $tempRoot = Join-Path $env:TEMP ("InfrastructureHealth-OSD-" + [Guid]::NewGuid().ToString("N"))
    $zipPath = Join-Path $tempRoot "openseadragon.zip"
    $extractPath = Join-Path $tempRoot "extract"

    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $PinnedOpenSeadragonReleaseUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 60
        $downloadHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($downloadHash -ne $PinnedOpenSeadragonReleaseSha256) {
            throw "OpenSeadragon release archive SHA-256 mismatch. Expected $PinnedOpenSeadragonReleaseSha256, got $downloadHash."
        }
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractPath -Force

        $downloaded = Get-ChildItem -LiteralPath $extractPath -Recurse -File -Filter "openseadragon.min.js" -ErrorAction Stop |
            Select-Object -First 1
        if (-not $downloaded) {
            throw "The OpenSeadragon release archive did not contain openseadragon.min.js."
        }
        if (-not (Test-PinnedOpenSeadragonFile -Path $downloaded.FullName -Version $PinnedOpenSeadragonVersion)) {
            throw "Downloaded OpenSeadragon file did not report the expected version $PinnedOpenSeadragonVersion."
        }

        Copy-Item -LiteralPath $downloaded.FullName -Destination $target -Force
        return [pscustomobject]@{ Available=$true; Source="downloaded official release"; Path=$target; Error=$null }
    }
    catch {
        return [pscustomobject]@{ Available=$false; Source=$null; Path=$target; Error=$_.Exception.Message }
    }
    finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if (-not (Test-Administrator)) {
    throw "Administrator privileges are required. Start Windows PowerShell as Administrator."
}

$existingConfigPath = Join-Path $InstallRoot "config\health.ini"
$existingConfig = $null
$isUpgrade = Test-Path -LiteralPath $existingConfigPath

if ($isUpgrade) {
    try {
        $existingConfig = Read-IniFile -Path $existingConfigPath
    }
    catch {
        Write-Step "Existing configuration" ("WARN ({0})" -f $_.Exception.Message) Yellow
    }
}

# Preserve non-default topology selectors from an existing installation unless
# the caller explicitly supplied the corresponding parameter for this run.
if ($existingConfig) {
    if (-not $PSBoundParameters.ContainsKey("SiteName")) {
        $SiteName = [string](Get-ExistingConfigValue $existingConfig "Paths" "SiteName" $SiteName)
    }
    if (-not $PSBoundParameters.ContainsKey("ApplicationPath")) {
        $ApplicationPath = [string](Get-ExistingConfigValue $existingConfig "Paths" "ApplicationPath" $ApplicationPath)
    }
    if (-not $PSBoundParameters.ContainsKey("ImagesVirtualDirectory")) {
        $ImagesVirtualDirectory = [string](Get-ExistingConfigValue $existingConfig "Paths" "ImagesVirtualDirectory" $ImagesVirtualDirectory)
    }
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Infrastructure Health & Benchmark" -ForegroundColor Cyan
Write-Host (" {0} - {1}" -f $(if ($isUpgrade) { "Upgrade" } else { "Installation" }), $ProductVersion) -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Import-Module WebAdministration -ErrorAction Stop
Write-Step "IIS WebAdministration module" "PASS" Green

$site = Get-Website -Name $SiteName -ErrorAction Stop
Write-Step "IIS site" ("PASS ({0})" -f $SiteName) Green

$appName = $ApplicationPath.Trim('/')
$app = Get-WebApplication -Site $SiteName -ErrorAction Stop |
    Where-Object { $_.Path -ieq $ApplicationPath } |
    Select-Object -First 1

if (-not $app -and -not $ApplicationPhysicalPath) {
    throw "Application application '$ApplicationPath' was not found under IIS site '$SiteName'."
}

if (-not $ApplicationPhysicalPath) {
    $ApplicationPhysicalPath = Expand-PathValue $app.PhysicalPath
}
else {
    $ApplicationPhysicalPath = Expand-PathValue $ApplicationPhysicalPath
}

if (-not (Test-Path -LiteralPath $ApplicationPhysicalPath)) {
    throw "Application physical path does not exist: $ApplicationPhysicalPath"
}
Write-Step "Application physical path" $ApplicationPhysicalPath Green

$dziPath = Join-Path $ApplicationPhysicalPath $DziSubdirectory
if (Test-Path -LiteralPath $dziPath) {
    Write-Step "DZI base path" $dziPath Green
}
else {
    Write-Step "DZI base path" ("WARN (not found: {0})" -f $dziPath) Yellow
}
$dziFramework = Get-DziFrameworkSummary -DziPath $dziPath
if ($dziFramework.available -and $dziFramework.framework -ne "Unknown DZI viewer") {
    Write-Step "Application DZI framework" ("PASS ({0})" -f $dziFramework.framework) Green
}
if ($dziFramework.available -and $dziFramework.framework -eq "Unknown DZI viewer") {
    Write-Step "Application DZI framework" "WARN (unknown implementation)" Yellow
}
elseif (-not $dziFramework.available) {
    Write-Step "Application DZI framework" "WARN (DZI directory missing)" Yellow
}

$vdir = $null
if ($app) {
    try {
        $vdir = Get-WebVirtualDirectory -Site $SiteName -Application $appName -ErrorAction Stop |
            Where-Object { $_.Path -ieq ("/" + $ImagesVirtualDirectory.Trim('/')) } |
            Select-Object -First 1
    }
    catch {
        $vdir = $null
    }
}

if ($vdir) {
    $detectedImagesPath = Expand-PathValue $vdir.PhysicalPath
    if ($ImagesPhysicalPath -and (Normalize-InfrastructurePath $ImagesPhysicalPath) -ne (Normalize-InfrastructurePath $detectedImagesPath)) {
        Write-Step "Images path override" "WARN (IIS value takes precedence)" Yellow
    }
    $ImagesPhysicalPath = $detectedImagesPath
}
elseif (-not $ImagesPhysicalPath) {
    throw "IIS virtual directory '$ImagesVirtualDirectory' could not be detected. Use -ImagesPhysicalPath only as an installation fallback."
}

$ImagesPhysicalPath = Expand-PathValue $ImagesPhysicalPath
Write-Step "IIS images physical path" $ImagesPhysicalPath Green

$healthPath = Join-Path $ApplicationPhysicalPath "health"
if ((Test-Path -LiteralPath $healthPath) -and -not $isUpgrade -and -not $Force) {
    throw "A health folder already exists at '$healthPath', but no managed Infrastructure Health & Benchmark installation was detected. Use -Force to replace it."
}

$engineScript = Join-Path $InstallRoot "Engine\Update-InfrastructureHealth.ps1"
$configPath = Join-Path $InstallRoot "config\health.ini"
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Select-Object -First 1
$taskWasEnabled = $false
$taskWasRunning = $false
$taskTemporarilyDisabled = $false

if ($existingTask) {
    $taskWasEnabled = ($existingTask.State -ne "Disabled")
    $taskWasRunning = ($existingTask.State -eq "Running")

    $actionText = (@($existingTask.Actions) | ForEach-Object { ([string]$_.Execute) + " " + ([string]$_.Arguments) }) -join " | "
    if ($actionText -notlike "*$InstallRoot*") {
        throw "Existing scheduled task '$TaskName' points to a different install root. To preserve stored credentials, this upgrade will not replace that task automatically."
    }

    if ($taskWasRunning) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    }
    Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
    $taskTemporarilyDisabled = $true

    $principalText = if ($existingTask.Principal.UserId) { $existingTask.Principal.UserId } else { "existing principal" }
    Write-Step "Scheduled task credentials" ("PRESERVED ({0})" -f $principalText) Green
}

$preservedVendorTemp = $null
$existingPinnedVendor = Join-Path $healthPath ("vendor\openseadragon\" + $PinnedOpenSeadragonVersion + "\openseadragon.min.js")
$existingLegacyVendor = Join-Path $healthPath "vendor\openseadragon.min.js"
$vendorToPreserve = $null
if (Test-PinnedOpenSeadragonFile -Path $existingPinnedVendor -Version $PinnedOpenSeadragonVersion) {
    $vendorToPreserve = $existingPinnedVendor
}
elseif (Test-PinnedOpenSeadragonFile -Path $existingLegacyVendor -Version $PinnedOpenSeadragonVersion) {
    # Migration path from the 0.1.1 non-versioned vendor location.
    $vendorToPreserve = $existingLegacyVendor
}
if ($vendorToPreserve) {
    $preservedVendorTemp = Join-Path $env:TEMP ("InfrastructureHealth-openseadragon-" + $PinnedOpenSeadragonVersion + "-" + [Guid]::NewGuid().ToString("N") + ".js")
    Copy-Item -LiteralPath $vendorToPreserve -Destination $preservedVendorTemp -Force
}

try {
    if (Test-Path -LiteralPath $healthPath) {
        Remove-Item -LiteralPath $healthPath -Recurse -Force
    }
    New-Item -ItemType Directory -Path $healthPath -Force | Out-Null
    Copy-Item -Path (Join-Path $PSScriptRoot "Web\*") -Destination $healthPath -Recurse -Force
    Write-Step "Static dashboard" $(if ($isUpgrade) { "UPDATED" } else { "PASS" }) Green

    # The Health dashboard uses its own pinned OpenSeadragon runtime. This is
    # intentionally independent from the DZI framework shipped by Application.
    $vendorResult = Install-PinnedOpenSeadragonVendor -HealthPath $healthPath -PreservedVendorFile $preservedVendorTemp
    if ($vendorResult.Available) {
        Write-Step "Health preview engine" ("PASS (OpenSeadragon {0} / {1})" -f $PinnedOpenSeadragonVersion, $vendorResult.Source) Green
    }
    else {
        Write-Step "Health preview engine" ("WARN (OpenSeadragon {0} unavailable: {1})" -f $PinnedOpenSeadragonVersion, $vendorResult.Error) Yellow
        Write-Step "Health preview fallback" "PASS (raw tile benchmark remains available)" Green
    }

    $dataPath = Join-Path $healthPath "data"
    Ensure-RandomFile -Path (Join-Path $dataPath "1MB.bin") -SizeBytes 1MB
    Ensure-RandomFile -Path (Join-Path $dataPath "16MB.bin") -SizeBytes 16MB
    Ensure-RandomFile -Path (Join-Path $dataPath "64MB.bin") -SizeBytes 64MB
    Write-Step "HTTP benchmark data" "PASS" Green

    $datasetPath = Join-Path $ImagesPhysicalPath $ImageBenchmarkSubdirectory
    $datasetInstalled = $false
    if (-not $SkipBenchmarkDataset) {
        try {
            if (-not (Test-Path -LiteralPath $datasetPath)) {
                New-Item -ItemType Directory -Path $datasetPath -Force | Out-Null
            }
            Copy-Item -Path (Join-Path $PSScriptRoot "TestDataset\*") -Destination $datasetPath -Recurse -Force
            Ensure-RandomFile -Path (Join-Path $datasetPath "storage-test.bin") -SizeBytes 64MB
            $datasetInstalled = $true
            Write-Step "Storage/DZI benchmark dataset" "PASS" Green
        }
        catch {
            Write-Step "Storage/DZI benchmark dataset" ("WARN ({0})" -f $_.Exception.Message) Yellow
        }
    }
    else {
        Write-Step "Storage/DZI benchmark dataset" "SKIPPED" Yellow
    }

    if (-not $datasetInstalled) {
        try {
            $tileProbe = Join-Path $datasetPath "benchmark_files\10\0_0.png"
            if (Test-Path -LiteralPath $tileProbe -ErrorAction SilentlyContinue) {
                $datasetInstalled = $true
            }
        }
        catch {
            # Keep the current state. The browser will not auto-run tiles when disabled.
        }
    }

    # Optional local reference Golden Reference dataset. The base package may
    # intentionally omit it because the real reference payload can be hundreds of MB.
    # If a prepared ReferenceDataset is packaged beside the installer, deploy it.
    # Otherwise preserve any reference dataset already installed on image storage.
    $referenceSource = Join-Path $PSScriptRoot "ReferenceDataset"
    $referenceSourceCatalog = Join-Path $referenceSource "reference.json"
    $referenceTarget = Join-Path $datasetPath "reference"
    $referenceTargetCatalog = Join-Path $referenceTarget "reference.json"
    if (Test-Path -LiteralPath $referenceSourceCatalog) {
        try {
            if (Test-Path -LiteralPath $referenceTarget) {
                Remove-Item -LiteralPath $referenceTarget -Recurse -Force
            }
            New-Item -ItemType Directory -Path $referenceTarget -Force | Out-Null
            Copy-Item -Path (Join-Path $referenceSource "*") -Destination $referenceTarget -Recurse -Force
            Write-Step "Real reference benchmark" "PASS (packaged dataset deployed)" Green
        }
        catch {
            Write-Step "Real reference benchmark" ("WARN ({0})" -f $_.Exception.Message) Yellow
        }
    }
    elseif (Test-Path -LiteralPath $referenceTargetCatalog -ErrorAction SilentlyContinue) {
        Write-Step "Real reference benchmark" "PRESERVED (existing dataset)" Green
    }
    else {
        Write-Step "Real reference benchmark" "NOT INSTALLED (Quick Test remains available)" Yellow
    }

    # Replace the engine but retain logs and the scheduled task itself.
    if (-not (Test-Path -LiteralPath $InstallRoot)) {
        New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    }
    New-Item -ItemType Directory -Path (Join-Path $InstallRoot "Logs") -Force | Out-Null

    $installedEngine = Join-Path $InstallRoot "Engine"
    if (Test-Path -LiteralPath $installedEngine) {
        Remove-Item -LiteralPath $installedEngine -Recurse -Force
    }
    Copy-Item -Path (Join-Path $PSScriptRoot "Engine") -Destination $InstallRoot -Recurse -Force

    $installedConfigDir = Join-Path $InstallRoot "config"
    New-Item -ItemType Directory -Path $installedConfigDir -Force | Out-Null

    $storageSampleBytes = [string](Get-ExistingConfigValue $existingConfig "Health" "StorageSampleBytes" "1048576")
    $storageFullBytes = [string](Get-ExistingConfigValue $existingConfig "Health" "StorageFullBytes" "67108864")
    $updateIntervalSeconds = [string](Get-ExistingConfigValue $existingConfig "Health" "UpdateIntervalSeconds" "60")

    $thresholdDefaults = [ordered]@{
        ClientTtfbGoodMs = "15"
        ClientTtfbWarningMs = "50"
        ClientThroughputGoodMbps = "100"
        ClientThroughputWarningMbps = "50"
        StorageDirectoryGoodMs = "10"
        StorageDirectoryWarningMs = "30"
        StorageOpenGoodMs = "10"
        StorageOpenWarningMs = "30"
        StorageReadGoodMBps = "100"
        StorageReadWarningMBps = "50"
        TileP95GoodMs = "100"
        TileP95WarningMs = "250"
    }

    $thresholdLines = @()
    foreach ($key in $thresholdDefaults.Keys) {
        $value = [string](Get-ExistingConfigValue $existingConfig "Thresholds" $key $thresholdDefaults[$key])
        $thresholdLines += ("{0}={1}" -f $key, $value)
    }

    $diagnosticLines = @()
    foreach ($key in @('DsnName','ImagePathRegistryKey','ImagePathRegistryValue','SqlProbeQueryFile')) {
        $default = if ($key -eq 'DsnName') { 'HealthCheck' } elseif ($key -eq 'ImagePathRegistryValue') { 'image_path' } else { '' }
        $value = [string](Get-ExistingConfigValue $existingConfig 'Diagnostics' $key $default)
        $diagnosticLines += ("{0}={1}" -f $key, $value)
    }

    $configText = @"
[Paths]
SiteName=$SiteName
ApplicationPath=$ApplicationPath
ImagesVirtualDirectory=$ImagesVirtualDirectory

[Health]
Version=$ProductVersion
UpdateIntervalSeconds=$updateIntervalSeconds
StorageSampleBytes=$storageSampleBytes
StorageFullBytes=$storageFullBytes
BenchmarkDatasetEnabled=$($datasetInstalled.ToString())

[Diagnostics]
$($diagnosticLines -join "`r`n")

[Thresholds]
$($thresholdLines -join "`r`n")
"@

    Set-Content -LiteralPath $configPath -Value $configText -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $InstallRoot "VERSION") -Value $ProductVersion -Encoding ASCII
    Write-Step "PowerShell diagnostic engine" $(if ($isUpgrade) { "UPDATED" } else { "PASS" }) Green

    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $engineScript -ConfigPath $configPath
    if ($LASTEXITCODE -ne 0) {
        throw "Initial health worker execution failed with exit code $LASTEXITCODE."
    }
    Write-Step "Installer-context health check" "PASS" Green

    if (-not $existingTask) {
        $taskCommand = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $engineScript + '" -ConfigPath "' + $configPath + '"'
        $taskMinutes = [Math]::Max(1, [int][Math]::Ceiling(([double]$updateIntervalSeconds) / 60.0))
        & schtasks.exe /Create /TN $TaskName /TR $taskCommand /SC MINUTE /MO $taskMinutes /RU SYSTEM /RL HIGHEST /F | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create scheduled task '$TaskName'. schtasks.exe exit code: $LASTEXITCODE"
        }
        Write-Step "Scheduled health task" ("PASS (SYSTEM / every {0} minute(s))" -f $taskMinutes) Green
    }
    else {
        Write-Step "Scheduled health task" "PASS (definition preserved)" Green
    }

    $appUrl = "/" + $appName
    $smokeUrl = "http://localhost" + $appUrl + "/health/"
    try {
        $response = Invoke-WebRequest -Uri ($smokeUrl + "?vlh=" + [DateTime]::UtcNow.Ticks) -UseBasicParsing -TimeoutSec 10
        if ($response.StatusCode -eq 200) {
            Write-Step "HTTP smoke test" "PASS (200)" Green
        }
        else {
            Write-Step "HTTP smoke test" ("WARN (HTTP {0})" -f $response.StatusCode) Yellow
        }
    }
    catch {
        Write-Step "HTTP smoke test" ("WARN ({0})" -f $_.Exception.Message) Yellow
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host (" {0} completed" -f $(if ($isUpgrade) { "Upgrade" } else { "Installation" })) -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ("Dashboard: http://localhost{0}/health/" -f $appUrl)
    Write-Host ("Health JSON: http://localhost{0}/health/api/server-health.json" -f $appUrl)
    Write-Host ("Current IIS image path: {0}" -f $ImagesPhysicalPath)
    Write-Host ("Storage benchmark dataset: {0}" -f $datasetPath)
    if ($existingTask) {
        Write-Host "Scheduled task credentials/principal were not changed."
    }
    Write-Host ""
    Write-Host "Run a server-side full storage sample manually with:"
    Write-Host ('  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -Full' -f $engineScript, $configPath)
    Write-Host ""
}
finally {
    if ($preservedVendorTemp) {
        Remove-Item -LiteralPath $preservedVendorTemp -Force -ErrorAction SilentlyContinue
    }

    if ($existingTask -and $taskTemporarilyDisabled -and $taskWasEnabled) {
        try {
            Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
            Start-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
            Write-Step "Scheduled task state" "RESTORED (enabled / triggered)" Green
        }
        catch {
            Write-Step "Scheduled task state" ("WARN (could not re-enable: {0})" -f $_.Exception.Message) Yellow
        }
    }
    elseif ($existingTask -and $taskTemporarilyDisabled -and -not $taskWasEnabled) {
        Write-Step "Scheduled task state" "PRESERVED (disabled)" Yellow
    }
}
