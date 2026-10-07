#requires -version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$ConfigPath,
    [switch]$Full
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "InfrastructureHealth.Common.ps1")

$BrokerRegistryKey = ""
$BrokerImagePathValue = "image_path"
$DsnName = ""
$ImageBenchmarkSubdirectory = "__Infrastructure_Health__"
$DziSubdirectory = "dzi"
$PinnedHealthOpenSeadragonVersion = "6.1.0"

function Expand-PathValue {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Value
    }
    return [Environment]::ExpandEnvironmentVariables($Value)
}

function Get-OdbcDsnMetadata {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("32-bit", "64-bit")][string]$Bitness,
        [Parameter(Mandatory=$true)][string]$Name
    )

    if ($Bitness -eq "64-bit") {
        $dsnRoot = "HKLM:\SOFTWARE\ODBC\ODBC.INI"
    }
    else {
        $dsnRoot = "HKLM:\SOFTWARE\WOW6432Node\ODBC\ODBC.INI"
    }

    $dsnPath = Join-Path $dsnRoot $Name
    $sourcesPath = Join-Path $dsnRoot "ODBC Data Sources"
    $result = [ordered]@{
        bitness = $Bitness
        dsn = $Name
        exists = $false
        driver = $null
        server = $null
        database = $null
        lastUser = $null
        trustedConnection = $null
        error = $null
    }

    try {
        if (-not (Test-Path -LiteralPath $dsnPath)) {
            $result.error = "System DSN not found."
            return $result
        }

        $result.exists = $true
        $properties = Get-ItemProperty -LiteralPath $dsnPath -ErrorAction Stop

        if ($properties.PSObject.Properties.Name -contains "Server") {
            $result.server = [string]$properties.Server
        }
        if ($properties.PSObject.Properties.Name -contains "Database") {
            $result.database = [string]$properties.Database
        }
        if ($properties.PSObject.Properties.Name -contains "Driver") {
            $result.driver = [string]$properties.Driver
        }
        if ($properties.PSObject.Properties.Name -contains "LastUser") {
            $result.lastUser = [string]$properties.LastUser
        }
        if ($properties.PSObject.Properties.Name -contains "Trusted_Connection") {
            $result.trustedConnection = [string]$properties.Trusted_Connection
        }

        if (Test-Path -LiteralPath $sourcesPath) {
            $sources = Get-ItemProperty -LiteralPath $sourcesPath -ErrorAction SilentlyContinue
            if ($sources -and $sources.PSObject.Properties.Name -contains $Name) {
                $result.driver = [string]$sources.$Name
            }
        }
    }
    catch {
        $result.error = $_.Exception.Message
    }

    return $result
}

function Invoke-OdbcProbe {
    param(
        [Parameter(Mandatory=$true)][ValidateSet("32-bit", "64-bit")][string]$Bitness,
        [Parameter(Mandatory=$true)][string]$Name
    )

    $result = [ordered]@{
        available = $false
        bitness = $Bitness
        dsn = $Name
        imagePath = $null
        serverName = $null
        databaseName = $null
        authentication = "Windows Integrated"
        runAs = $null
        error = $null
    }

    $helper = Join-Path $PSScriptRoot "Test-InfrastructureOdbc.ps1"
    if (-not (Test-Path -LiteralPath $helper)) {
        $result.error = "ODBC helper script not found."
        return $result
    }

    if ($Bitness -eq "64-bit") {
        if ([IntPtr]::Size -eq 4) {
            $powershellPath = Join-Path $env:WINDIR "Sysnative\WindowsPowerShell\v1.0\powershell.exe"
        }
        else {
            $powershellPath = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
        }
    }
    else {
        $powershellPath = Join-Path $env:WINDIR "SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
    }

    if (-not (Test-Path -LiteralPath $powershellPath)) {
        $result.error = "$Bitness Windows PowerShell executable not found."
        return $result
    }

    $probeOutput = Join-Path $env:TEMP (([IO.Path]::GetRandomFileName()) + ".json")
    try {
        & $powershellPath -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $helper -DsnName $Name -ConfigPath $ConfigPath -OutputPath $probeOutput 2>$null | Out-Null
        if (-not (Test-Path -LiteralPath $probeOutput)) {
            $result.error = "ODBC probe returned no data."
            return $result
        }

        $text = [IO.File]::ReadAllText($probeOutput, [Text.Encoding]::UTF8).Trim()
        if ([string]::IsNullOrWhiteSpace($text)) {
            $result.error = "ODBC probe returned no data."
            return $result
        }

        $parsed = $text | ConvertFrom-Json -ErrorAction Stop
        $result.available = [bool]$parsed.available
        $result.imagePath = if ($parsed.imagePath) { [string]$parsed.imagePath } else { $null }
        $result.serverName = if ($parsed.serverName) { [string]$parsed.serverName } else { $null }
        $result.databaseName = if ($parsed.databaseName) { [string]$parsed.databaseName } else { $null }
        $result.authentication = if ($parsed.authentication) { [string]$parsed.authentication } else { "Windows Integrated" }
        $result.runAs = if ($parsed.runAs) { [string]$parsed.runAs } else { $null }
        $result.error = if ($parsed.error) { [string]$parsed.error } else { $null }
    }
    catch {
        $result.error = $_.Exception.Message
    }
    finally {
        Remove-Item -LiteralPath $probeOutput -Force -ErrorAction SilentlyContinue
    }

    return $result
}

function Get-DziFrameworkDiscovery {
    param([AllowNull()][string]$DziPath)

    $result = [ordered]@{
        dziPath = $DziPath
        dziAvailable = $false
        framework = "None"
        frameworkPath = $null
        legacySeadragonDetected = $false
        legacySeadragonPath = $null
        legacySeadragonComponents = [ordered]@{
            core = $false
            config = $false
            deepZoom = $false
            tileSource = $false
            viewer = $false
        }
        openSeadragonDetected = $false
        openSeadragonPath = $null
        discoveryError = $null
    }

    if ([string]::IsNullOrWhiteSpace($DziPath) -or -not (Test-Path -LiteralPath $DziPath)) {
        return $result
    }

    $result.dziAvailable = $true

    try {
        # Legacy Microsoft Seadragon Ajax / Deep Zoom layout used by existing
        # Application releases. The product template loads these modules from
        # <Application base>\dzi\seadragon\src in a defined order.
        $legacyPath = Join-Path $DziPath "seadragon\src"
        $legacyFiles = [ordered]@{
            core = "Seadragon.Core.js"
            config = "Seadragon.Config.js"
            deepZoom = "Seadragon.DeepZoom.js"
            tileSource = "Seadragon.TileSource.js"
            viewer = "Seadragon.Viewer.js"
        }

        foreach ($key in $legacyFiles.Keys) {
            $result.legacySeadragonComponents[$key] = [bool](Test-Path -LiteralPath (Join-Path $legacyPath $legacyFiles[$key]))
        }

        $legacyRequired = @("core", "deepZoom", "tileSource", "viewer")
        $legacyOk = $true
        foreach ($key in $legacyRequired) {
            if (-not $result.legacySeadragonComponents[$key]) {
                $legacyOk = $false
                break
            }
        }

        if ($legacyOk) {
            $result.legacySeadragonDetected = $true
            $result.legacySeadragonPath = $legacyPath
        }

        # Also detect modern OpenSeadragon when a future Application release ships it.
        $osd = Get-ChildItem -LiteralPath $DziPath -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^openseadragon(\.min)?\.js$' } |
            Sort-Object { if ($_.Name -like '*.min.js') { 0 } else { 1 } }, Length |
            Select-Object -First 1

        if ($osd) {
            $result.openSeadragonDetected = $true
            $result.openSeadragonPath = $osd.FullName
        }

        if ($result.legacySeadragonDetected -and $result.openSeadragonDetected) {
            $result.framework = "Legacy Seadragon + OpenSeadragon"
            $result.frameworkPath = $result.legacySeadragonPath
        }
        elseif ($result.legacySeadragonDetected) {
            $result.framework = "Legacy Seadragon"
            $result.frameworkPath = $result.legacySeadragonPath
        }
        elseif ($result.openSeadragonDetected) {
            $result.framework = "OpenSeadragon"
            $result.frameworkPath = $result.openSeadragonPath
        }
        else {
            $result.framework = "Unknown DZI viewer"
            $result.frameworkPath = $DziPath
        }
    }
    catch {
        $result.discoveryError = $_.Exception.Message
        if ($result.framework -eq "None") {
            $result.framework = "Unknown DZI viewer"
        }
    }

    return $result
}
function Get-ReferenceBenchmarkSummary {
    param([AllowNull()][string]$BenchmarkPath)

    $result = [ordered]@{
        available = $false
        catalogPath = $null
        referenceVersion = $null
        profile = $null
        enabledTemplates = @()
        datasetSha256 = $null
        payloadFileCount = $null
        payloadBytes = $null
        error = $null
    }

    if ([string]::IsNullOrWhiteSpace($BenchmarkPath)) { return $result }
    $catalog = Join-Path $BenchmarkPath "reference\reference.json"
    $result.catalogPath = $catalog
    if (-not (Test-Path -LiteralPath $catalog -ErrorAction SilentlyContinue)) { return $result }

    try {
        $text = [IO.File]::ReadAllText($catalog, [Text.Encoding]::UTF8)
        $parsed = $text | ConvertFrom-Json -ErrorAction Stop
        $result.available = $true
        $result.referenceVersion = if ($parsed.referenceVersion) { [string]$parsed.referenceVersion } else { $null }
        $result.profile = if ($parsed.profile) { [string]$parsed.profile } else { $null }
        $result.enabledTemplates = @($parsed.enabledTemplates | ForEach-Object { [string]$_ })
        $result.datasetSha256 = if ($parsed.datasetSha256) { [string]$parsed.datasetSha256 } else { $null }
        $result.payloadFileCount = if ($null -ne $parsed.payloadFileCount) { [int]$parsed.payloadFileCount } else { $null }
        $result.payloadBytes = if ($null -ne $parsed.payloadBytes) { [int64]$parsed.payloadBytes } else { $null }
    }
    catch {
        $result.error = $_.Exception.Message
    }
    return $result
}

function Measure-Storage {
    param(
        [AllowNull()][string]$ImagesPath,
        [AllowNull()][string]$BenchmarkPath,
        [int64]$SampleBytes
    )

    $result = [ordered]@{
        path = $ImagesPath
        available = $false
        benchmarkAvailable = $false
        directoryLatencyMs = $null
        openLatencyMs = $null
        sampleBytes = 0
        readMBps = $null
        mode = $(if ($Full) { "full" } else { "lightweight" })
        readScored = [bool]$Full
        smbServer = $null
        smbDialect = $null
        error = $null
    }

    if ([string]::IsNullOrWhiteSpace($ImagesPath)) {
        $result.error = "IIS images physical path is unavailable."
        return $result
    }

    if ($ImagesPath -match '^\\\\([^\\]+)\\') {
        $result.smbServer = $Matches[1]
    }

    try {
        $result.available = [bool](Test-Path -LiteralPath $ImagesPath -ErrorAction Stop)
        if (-not $result.available) {
            $result.error = "Storage path is not reachable."
            return $result
        }

        $sw = [Diagnostics.Stopwatch]::StartNew()
        Get-ChildItem -LiteralPath $ImagesPath -Force -ErrorAction Stop | Select-Object -First 10 | Out-Null
        $sw.Stop()
        $result.directoryLatencyMs = [Math]::Round($sw.Elapsed.TotalMilliseconds, 2)

        if ([string]::IsNullOrWhiteSpace($BenchmarkPath)) {
            return $result
        }

        $testFile = Join-Path $BenchmarkPath "storage-test.bin"
        if (-not (Test-Path -LiteralPath $testFile -ErrorAction SilentlyContinue)) {
            return $result
        }
        $result.benchmarkAvailable = $true

        $sw.Restart()
        $stream = New-Object IO.FileStream($testFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite, 1MB, [IO.FileOptions]::SequentialScan)
        $sw.Stop()
        $result.openLatencyMs = [Math]::Round($sw.Elapsed.TotalMilliseconds, 2)

        try {
            $buffer = New-Object byte[] (1MB)
            $remaining = [Math]::Min([int64]$SampleBytes, $stream.Length)
            $total = 0L
            $readSw = [Diagnostics.Stopwatch]::StartNew()

            while ($remaining -gt 0) {
                $requested = [int][Math]::Min($buffer.Length, $remaining)
                $count = $stream.Read($buffer, 0, $requested)
                if ($count -le 0) {
                    break
                }
                $total += $count
                $remaining -= $count
            }

            $readSw.Stop()
            $result.sampleBytes = $total
            if ($readSw.Elapsed.TotalSeconds -gt 0 -and $total -gt 0) {
                $result.readMBps = [Math]::Round(($total / 1MB) / $readSw.Elapsed.TotalSeconds, 2)
            }
        }
        finally {
            $stream.Dispose()
        }

        if ($result.smbServer) {
            try {
                $connection = Get-SmbConnection -ErrorAction SilentlyContinue |
                    Where-Object { $_.ServerName -ieq $result.smbServer } |
                    Select-Object -First 1
                if ($connection -and $connection.Dialect) {
                    $result.smbDialect = [string]$connection.Dialect
                }
            }
            catch {
                # SMB dialect is best-effort metadata and must not fail the health check.
            }
        }
    }
    catch {
        $result.error = $_.Exception.Message
    }

    return $result
}

function New-ConfigurationConsistency {
    param(
        [AllowNull()][string]$RegistryPath,
        [AllowNull()][string]$Sql64Path,
        [AllowNull()][string]$Sql32Path,
        [AllowNull()][string]$IisPath,
        [bool]$Sql64Available,
        [bool]$Sql32Available,
        [AllowNull()][string]$Sql64Server,
        [AllowNull()][string]$Sql32Server,
        [AllowNull()][string]$Sql64Database,
        [AllowNull()][string]$Sql32Database
    )

    $registryVsSql64 = Test-NormalizedPathEqual $RegistryPath $Sql64Path
    $registryVsSql32 = Test-NormalizedPathEqual $RegistryPath $Sql32Path
    $sql64VsSql32 = Test-NormalizedPathEqual $Sql64Path $Sql32Path
    $registryVsIis = Test-NormalizedPathEqual $RegistryPath $IisPath
    $sql64VsIis = Test-NormalizedPathEqual $Sql64Path $IisPath
    $sql32VsIis = Test-NormalizedPathEqual $Sql32Path $IisPath

    $sqlServerMatch = $null
    if (-not [string]::IsNullOrWhiteSpace($Sql64Server) -and -not [string]::IsNullOrWhiteSpace($Sql32Server)) {
        $sqlServerMatch = [bool]($Sql64Server.Trim() -ieq $Sql32Server.Trim())
    }

    $sqlDatabaseMatch = $null
    if (-not [string]::IsNullOrWhiteSpace($Sql64Database) -and -not [string]::IsNullOrWhiteSpace($Sql32Database)) {
        $sqlDatabaseMatch = [bool]($Sql64Database.Trim() -ieq $Sql32Database.Trim())
    }

    $requiredAvailable = (
        -not [string]::IsNullOrWhiteSpace($RegistryPath) -and
        -not [string]::IsNullOrWhiteSpace($IisPath) -and
        $Sql64Available -and
        $Sql32Available -and
        -not [string]::IsNullOrWhiteSpace($Sql64Path) -and
        -not [string]::IsNullOrWhiteSpace($Sql32Path)
    )

    $comparisons = @(@(
        $registryVsSql64,
        $registryVsSql32,
        $sql64VsSql32,
        $registryVsIis,
        $sql64VsIis,
        $sql32VsIis
    ) | Where-Object { $null -ne $_ })

    $allMatch = $null
    if ($comparisons.Count -gt 0) {
        $allMatch = -not ($comparisons -contains $false)
    }

    $status = "WARNING"
    $message = "One or more configuration sources are unavailable."

    $sqlTargetMismatch = ($sqlServerMatch -eq $false -or $sqlDatabaseMatch -eq $false)

    if ($requiredAvailable -and $allMatch -eq $true -and -not $sqlTargetMismatch) {
        $status = "PASS"
        $message = "Registry, 32-bit ODBC/SQL, 64-bit ODBC/SQL, and IIS image paths match."
    }
    elseif ($sqlTargetMismatch) {
        $status = "WARNING"
        $message = "The 32-bit and 64-bit HealthCheck DSNs connect to different SQL targets."
    }
    elseif ($allMatch -eq $false) {
        $status = "WARNING"
        $message = "Application image path configuration sources do not match."
    }

    return [ordered]@{
        status = $status
        message = $message
        allRequiredAvailable = $requiredAvailable
        allMatch = $allMatch
        registryVsSql64 = $registryVsSql64
        registryVsSql32 = $registryVsSql32
        sql64VsSql32 = $sql64VsSql32
        registryVsIis = $registryVsIis
        sql64VsIis = $sql64VsIis
        sql32VsIis = $sql32VsIis
        sqlServerMatch = $sqlServerMatch
        sqlDatabaseMatch = $sqlDatabaseMatch
    }
}

$config = Read-IniFile -Path $ConfigPath
$BrokerRegistryKey = [string](Get-IniValue $config "Diagnostics" "ImagePathRegistryKey" "")
$BrokerImagePathValue = [string](Get-IniValue $config "Diagnostics" "ImagePathRegistryValue" "image_path")
$DsnName = [string](Get-IniValue $config "Diagnostics" "DsnName" "HealthCheck")
$siteName = [string](Get-IniValue -Config $config -Section "Paths" -Key "SiteName" -Default "Default Web Site")
$applicationPath = [string](Get-IniValue -Config $config -Section "Paths" -Key "ApplicationPath" -Default "/App")
$imagesVirtualDirectory = [string](Get-IniValue -Config $config -Section "Paths" -Key "ImagesVirtualDirectory" -Default "images")
$health = if ($config.ContainsKey("Health")) { $config["Health"] } else { @{} }
$thresholds = if ($config.ContainsKey("Thresholds")) { $config["Thresholds"] } else { @{} }

$version = [string](Get-IniValue -Config $config -Section "Health" -Key "Version" -Default "0.1.8")
$sampleBytes = if ($Full) {
    [int64](Get-IniValue -Config $config -Section "Health" -Key "StorageFullBytes" -Default "67108864")
}
else {
    [int64](Get-IniValue -Config $config -Section "Health" -Key "StorageSampleBytes" -Default "1048576")
}
$benchmarkDatasetEnabled = Convert-ToBoolean (Get-IniValue -Config $config -Section "Health" -Key "BenchmarkDatasetEnabled" -Default "true") $true

$cpu = $null
$memoryPercent = $null
$memoryTotalGB = $null
$memoryFreeGB = $null
$nics = @()
$ipAddresses = @()
$iisState = "Unknown"
$serverError = $null
$applicationPhysicalPath = $null
$iisImagesPhysicalPath = $null
$iisDiscoveryError = $null
$registryImagePath = $null
$registryError = $null

try {
    $processors = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
    if ($processors.Count -gt 0) {
        $cpu = [Math]::Round((($processors | Measure-Object -Property LoadPercentage -Average).Average), 1)
    }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $memoryTotalGB = [Math]::Round(([double]$os.TotalVisibleMemorySize / 1MB), 2)
    $memoryFreeGB = [Math]::Round(([double]$os.FreePhysicalMemory / 1MB), 2)
    if ([double]$os.TotalVisibleMemorySize -gt 0) {
        $memoryPercent = [Math]::Round((1.0 - ([double]$os.FreePhysicalMemory / [double]$os.TotalVisibleMemorySize)) * 100.0, 1)
    }

    $netAdapters = @(Get-CimInstance Win32_NetworkAdapter -Filter "NetEnabled=True" -ErrorAction SilentlyContinue)
    foreach ($adapter in $netAdapters) {
        $nics += [ordered]@{
            name = $adapter.Name
            macAddress = $adapter.MACAddress
            speedMbps = if ($adapter.Speed) { [Math]::Round(([double]$adapter.Speed / 1000000.0), 0) } else { $null }
        }
    }

    $ipConfigs = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" -ErrorAction SilentlyContinue)
    foreach ($ipConfig in $ipConfigs) {
        foreach ($address in @($ipConfig.IPAddress)) {
            if ($address -and $address -notmatch ':') {
                $ipAddresses += [string]$address
            }
        }
    }
    $ipAddresses = @($ipAddresses | Sort-Object -Unique)
}
catch {
    $serverError = $_.Exception.Message
}

try {
    Import-Module WebAdministration -ErrorAction Stop
    $site = Get-Website -Name $siteName -ErrorAction Stop
    $iisState = [string]$site.State

    $appName = $applicationPath.Trim('/')
    $app = Get-WebApplication -Site $siteName -ErrorAction Stop |
        Where-Object { $_.Path -ieq $applicationPath } |
        Select-Object -First 1

    if (-not $app) {
        throw "Application IIS application '$applicationPath' was not found."
    }

    $applicationPhysicalPath = Expand-PathValue $app.PhysicalPath

    $vdir = Get-WebVirtualDirectory -Site $siteName -Application $appName -ErrorAction Stop |
        Where-Object { $_.Path -ieq ("/" + $imagesVirtualDirectory.Trim('/')) } |
        Select-Object -First 1

    if (-not $vdir) {
        throw "IIS virtual directory '$imagesVirtualDirectory' was not found below '$applicationPath'."
    }

    $iisImagesPhysicalPath = Expand-PathValue $vdir.PhysicalPath
}
catch {
    $iisDiscoveryError = $_.Exception.Message
    if (-not $serverError) {
        $serverError = $iisDiscoveryError
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($BrokerRegistryKey)) { throw "Registry image-path check is not configured." }
    if (-not (Test-Path -LiteralPath $BrokerRegistryKey)) {
        throw "Broker registry key not found: $BrokerRegistryKey"
    }

    $broker = Get-ItemProperty -LiteralPath $BrokerRegistryKey -Name $BrokerImagePathValue -ErrorAction Stop
    $registryImagePath = Expand-PathValue ([string]$broker.$BrokerImagePathValue)
}
catch {
    $registryError = $_.Exception.Message
}

$dsn64Meta = Get-OdbcDsnMetadata -Bitness "64-bit" -Name $DsnName
$dsn32Meta = Get-OdbcDsnMetadata -Bitness "32-bit" -Name $DsnName
$sql64 = if ($dsn64Meta.exists) { Invoke-OdbcProbe -Bitness "64-bit" -Name $DsnName } else { [ordered]@{ available=$false; bitness="64-bit"; dsn=$DsnName; imagePath=$null; serverName=$null; databaseName=$null; authentication="Windows Integrated"; runAs=$null; error="System DSN not found." } }
$sql32 = if ($dsn32Meta.exists) { Invoke-OdbcProbe -Bitness "32-bit" -Name $DsnName } else { [ordered]@{ available=$false; bitness="32-bit"; dsn=$DsnName; imagePath=$null; serverName=$null; databaseName=$null; authentication="Windows Integrated"; runAs=$null; error="System DSN not found." } }

$dziPhysicalPath = if ($applicationPhysicalPath) { Join-Path $applicationPhysicalPath $DziSubdirectory } else { $null }
$dzi = Get-DziFrameworkDiscovery -DziPath $dziPhysicalPath

$imagesPathForBenchmark = $iisImagesPhysicalPath
$benchmarkPath = if ($imagesPathForBenchmark) { Join-Path $imagesPathForBenchmark $ImageBenchmarkSubdirectory } else { $null }
$appUrl = "/" + $applicationPath.Trim('/')
$imagesUrl = $appUrl + "/" + $imagesVirtualDirectory.Trim('/')
$benchmarkUrl = $imagesUrl + "/" + $ImageBenchmarkSubdirectory
$healthRoot = if ($applicationPhysicalPath) { Join-Path $applicationPhysicalPath "health" } else { $null }

if (-not $healthRoot) {
    throw "Unable to discover Application physical path. Health JSON output path cannot be resolved."
}

$healthPreviewPath = Join-Path $healthRoot ("vendor\openseadragon\" + $PinnedHealthOpenSeadragonVersion + "\openseadragon.min.js")
$healthPreviewAvailable = [bool](Test-Path -LiteralPath $healthPreviewPath -ErrorAction SilentlyContinue)

$outputPath = Join-Path $healthRoot "api\server-health.json"
$storage = Measure-Storage -ImagesPath $imagesPathForBenchmark -BenchmarkPath $benchmarkPath -SampleBytes $sampleBytes
$referenceBenchmark = Get-ReferenceBenchmarkSummary -BenchmarkPath $benchmarkPath

$consistency = New-ConfigurationConsistency `
    -RegistryPath $registryImagePath `
    -Sql64Path $sql64.imagePath `
    -Sql32Path $sql32.imagePath `
    -IisPath $iisImagesPhysicalPath `
    -Sql64Available ([bool]$sql64.available) `
    -Sql32Available ([bool]$sql32.available) `
    -Sql64Server $sql64.serverName `
    -Sql32Server $sql32.serverName `
    -Sql64Database $sql64.databaseName `
    -Sql32Database $sql32.databaseName

$thresholdObject = [ordered]@{}
foreach ($key in $thresholds.Keys) {
    $thresholdObject[$key] = Convert-ToDoubleOrNull $thresholds[$key]
}

$output = [ordered]@{
    schemaVersion = 5
    product = "Infrastructure Health & Benchmark"
    version = $version
    timestamp = (Get-Date).ToString("o")
    server = [ordered]@{
        hostname = $env:COMPUTERNAME
        runAs = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        ipAddresses = $ipAddresses
        iisSite = $siteName
        iisState = $iisState
        cpuPercent = $cpu
        memoryPercent = $memoryPercent
        memoryTotalGB = $memoryTotalGB
        memoryFreeGB = $memoryFreeGB
        networkAdapters = $nics
        error = $serverError
    }
    storage = $storage
    topology = [ordered]@{
        applicationPath = $applicationPath
        applicationPhysicalPath = $applicationPhysicalPath
        dziPhysicalPath = $dzi.dziPath
        dziAvailable = $dzi.dziAvailable
        dziFramework = $dzi.framework
        dziFrameworkPath = $dzi.frameworkPath
        legacySeadragonDetected = $dzi.legacySeadragonDetected
        legacySeadragonPath = $dzi.legacySeadragonPath
        legacySeadragonComponents = $dzi.legacySeadragonComponents
        openSeadragonDetected = $dzi.openSeadragonDetected
        openSeadragonPath = $dzi.openSeadragonPath
        dziDiscoveryError = $dzi.discoveryError
        healthPreviewEngine = "OpenSeadragon"
        healthPreviewVersion = $PinnedHealthOpenSeadragonVersion
        healthPreviewAvailable = $healthPreviewAvailable
        healthPreviewPath = $healthPreviewPath
        imagesVirtualDirectory = $imagesVirtualDirectory
        imagesPhysicalPath = $iisImagesPhysicalPath
        imageBenchmarkPhysicalPath = $benchmarkPath
        imageBenchmarkUrl = $benchmarkUrl
        imageBenchmarkConfigured = $benchmarkDatasetEnabled
        imageBenchmarkReachableFromWorker = $storage.benchmarkAvailable
        iisDiscoveryError = $iisDiscoveryError
    }
    referenceBenchmark = $referenceBenchmark
    configuration = [ordered]@{
        registry = [ordered]@{
            key = $BrokerRegistryKey
            valueName = $BrokerImagePathValue
            available = [bool](-not [string]::IsNullOrWhiteSpace($registryImagePath))
            imagePath = $registryImagePath
            error = $registryError
        }
        sql64 = [ordered]@{
            dsn = $DsnName
            dsnType = "System"
            bitness = "64-bit"
            dsnExists = [bool]$dsn64Meta.exists
            driver = $dsn64Meta.driver
            server = $dsn64Meta.server
            database = $dsn64Meta.database
            dsnLastUser = $dsn64Meta.lastUser
            dsnTrustedConnection = $dsn64Meta.trustedConnection
            healthAuthentication = $sql64.authentication
            healthRunAs = $sql64.runAs
            querySucceeded = [bool]$sql64.available
            actualServer = $sql64.serverName
            actualDatabase = $sql64.databaseName
            imagePath = $sql64.imagePath
            error = $sql64.error
        }
        sql32 = [ordered]@{
            dsn = $DsnName
            dsnType = "System"
            bitness = "32-bit"
            dsnExists = [bool]$dsn32Meta.exists
            driver = $dsn32Meta.driver
            server = $dsn32Meta.server
            database = $dsn32Meta.database
            dsnLastUser = $dsn32Meta.lastUser
            dsnTrustedConnection = $dsn32Meta.trustedConnection
            healthAuthentication = $sql32.authentication
            healthRunAs = $sql32.runAs
            querySucceeded = [bool]$sql32.available
            actualServer = $sql32.serverName
            actualDatabase = $sql32.databaseName
            imagePath = $sql32.imagePath
            error = $sql32.error
        }
        iis = [ordered]@{
            available = [bool](-not [string]::IsNullOrWhiteSpace($iisImagesPhysicalPath))
            virtualDirectory = $imagesUrl
            imagePath = $iisImagesPhysicalPath
            error = $iisDiscoveryError
        }
        consistency = $consistency
    }
    thresholds = $thresholdObject
}

Write-AtomicJson -InputObject $output -Path $outputPath
exit 0
