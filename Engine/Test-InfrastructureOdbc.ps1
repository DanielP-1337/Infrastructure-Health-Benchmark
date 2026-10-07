#requires -version 5.1
[CmdletBinding()]
param(
    [string]$DsnName = "HealthCheck",
    [string]$ConfigPath,
    [string]$OutputPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$result = [ordered]@{
    available = $false
    bitness = $(if ([IntPtr]::Size -eq 8) { "64-bit" } else { "32-bit" })
    dsn = $DsnName
    imagePath = $null
    serverName = $null
    databaseName = $null
    authentication = "Windows Integrated"
    runAs = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    error = $null
}

. (Join-Path $PSScriptRoot "InfrastructureHealth.Common.ps1")
$probeConfig = if ($ConfigPath) { Read-IniFile -Path $ConfigPath } else { @{} }
$queryPath = [string](Get-IniValue $probeConfig "Diagnostics" "SqlProbeQueryFile" "")

$connection = $null
$command = $null

try {
    $connection = New-Object System.Data.Odbc.OdbcConnection
    $connection.ConnectionString = "DSN=$DsnName;Trusted_Connection=Yes;"
    $connection.Open()

    $command = $connection.CreateCommand()
    $command.CommandTimeout = 5
    # A local, reviewed query can additionally return image_path as column three.
    $command.CommandText = "SELECT CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)), DB_NAME(), CAST(NULL AS nvarchar(4000));"
    if (-not [string]::IsNullOrWhiteSpace($queryPath)) {
        if (-not [IO.Path]::IsPathRooted($queryPath)) { $queryPath = Join-Path (Split-Path $ConfigPath -Parent) $queryPath }
        $command.CommandText = [IO.File]::ReadAllText($queryPath)
    }

    $reader = $command.ExecuteReader()
    try {
        if (-not $reader.Read()) {
            $result.error = "SQL probe returned no rows."
        }
        else {
            if (-not $reader.IsDBNull(0)) {
                $result.serverName = ([string]$reader.GetValue(0)).Trim()
            }
            if (-not $reader.IsDBNull(1)) {
                $result.databaseName = ([string]$reader.GetValue(1)).Trim()
            }
            if (-not $reader.IsDBNull(2)) {
                $result.imagePath = ([string]$reader.GetValue(2)).Trim()
            }

            $result.available = $true

        }
    }
    finally {
        $reader.Dispose()
    }
}
catch {
    $result.error = $_.Exception.Message
}
finally {
    if ($null -ne $command) {
        $command.Dispose()
    }
    if ($null -ne $connection) {
        if ($connection.State -ne [System.Data.ConnectionState]::Closed) {
            $connection.Close()
        }
        $connection.Dispose()
    }
}

$json = $result | ConvertTo-Json -Compress -Depth 5
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($OutputPath, $json, $utf8NoBom)
}
else {
    [Console]::Out.Write($json)
}
exit 0
