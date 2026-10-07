Set-StrictMode -Version 2.0

function Read-IniFile {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "INI file not found: $Path"
    }

    $result = @{}
    $section = ""

    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith(';') -or $line.StartsWith('#')) {
            continue
        }

        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1]
            if (-not $result.ContainsKey($section)) {
                $result[$section] = @{}
            }
            continue
        }

        $idx = $line.IndexOf('=')
        if ($idx -lt 1) {
            continue
        }

        $key = $line.Substring(0, $idx).Trim()
        $value = $line.Substring($idx + 1).Trim()

        if (-not $result.ContainsKey($section)) {
            $result[$section] = @{}
        }
        $result[$section][$key] = $value
    }

    return $result
}

function Get-IniValue {
    param(
        [Parameter(Mandatory=$true)][hashtable]$Config,
        [Parameter(Mandatory=$true)][string]$Section,
        [Parameter(Mandatory=$true)][string]$Key,
        $Default = $null
    )

    if ($Config.ContainsKey($Section) -and $Config[$Section].ContainsKey($Key)) {
        return $Config[$Section][$Key]
    }
    return $Default
}

function Convert-ToDoubleOrNull {
    param($Value)

    if ($null -eq $Value) {
        return $null
    }

    $parsed = 0.0
    if ([double]::TryParse(
        [string]$Value,
        [Globalization.NumberStyles]::Any,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsed
    )) {
        return $parsed
    }

    return $null
}

function Convert-ToBoolean {
    param($Value, [bool]$Default = $false)

    if ($null -eq $Value) {
        return $Default
    }

    $text = ([string]$Value).Trim()
    if ($text -match '^(1|true|yes|on)$') {
        return $true
    }
    if ($text -match '^(0|false|no|off)$') {
        return $false
    }
    return $Default
}

function Normalize-InfrastructurePath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    $normalized = [Environment]::ExpandEnvironmentVariables($Path.Trim())

    while ($normalized.Length -gt 3 -and $normalized.EndsWith('\')) {
        $normalized = $normalized.Substring(0, $normalized.Length - 1)
    }

    return $normalized.ToLowerInvariant()
}

function Test-NormalizedPathEqual {
    param(
        [AllowNull()][string]$Left,
        [AllowNull()][string]$Right
    )

    $leftNormalized = Normalize-InfrastructurePath $Left
    $rightNormalized = Normalize-InfrastructurePath $Right

    if ($null -eq $leftNormalized -or $null -eq $rightNormalized) {
        return $null
    }

    return [bool]($leftNormalized -eq $rightNormalized)
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory=$true)]$InputObject,
        [Parameter(Mandatory=$true)][string]$Path
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $temp = Join-Path $directory (([IO.Path]::GetRandomFileName()) + ".tmp")
    $json = $InputObject | ConvertTo-Json -Depth 16

    # PowerShell 5.1's Encoding.UTF8 emits a BOM. Use an explicit no-BOM encoder.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temp, $json, $utf8NoBom)

    if (Test-Path -LiteralPath $Path) {
        try {
            [IO.File]::Replace($temp, $Path, $null)
        }
        catch {
            Copy-Item -LiteralPath $temp -Destination $Path -Force
            Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        Move-Item -LiteralPath $temp -Destination $Path -Force
    }
}

function Get-Percentile {
    param([double[]]$Values, [double]$Percentile)

    if (-not $Values -or $Values.Count -eq 0) {
        return $null
    }

    $sorted = @($Values | Sort-Object)
    $rank = [Math]::Ceiling(($Percentile / 100.0) * $sorted.Count) - 1
    if ($rank -lt 0) {
        $rank = 0
    }
    if ($rank -ge $sorted.Count) {
        $rank = $sorted.Count - 1
    }

    return [Math]::Round([double]$sorted[$rank], 2)
}
