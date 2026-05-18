#Requires -Version 7.x
<#
.SYNOPSIS
    Show-AssetHeat — unified thermal dashboard for CPU, GPU, storage, motherboard, battery.

.DESCRIPTION
    Aggregates temperature data from every source Windows exposes:
      1. LibreHardwareMonitor / OpenHardwareMonitor WMI namespace  (best — CPU cores, GPU, mobo, VRM)
      2. nvidia-smi                                                (NVIDIA GPUs, no extra software)
      3. MSAcpi_ThermalZoneTemperature                              (ACPI thermal zones — coarse CPU/system)
      4. Get-PhysicalDisk + Get-StorageReliabilityCounter           (SSD/HDD/NVMe)
      5. Win32_Battery                                              (laptops)

.NOTES
    Run as Administrator for the most complete picture.
    For motherboard / VRM / per-core CPU data, install LibreHardwareMonitor and
    enable its "Run web server" / WMI provider option (or run LHM as admin once).
#>

[CmdletBinding()]
param(
    [switch]$Raw,                              # emit objects instead of a formatted table
    [int]$WatchSeconds = 0                     # >0 = refresh loop every N seconds
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------- helpers ----------------------------------------------------------

function New-Reading {
    param($Source, $Asset, $Sensor, [double]$Celsius)
    [pscustomobject]@{
        Source     = $Source
        Asset      = $Asset
        Sensor     = $Sensor
        Celsius    = [math]::Round($Celsius, 1)
        Fahrenheit = [math]::Round($Celsius * 9 / 5 + 32, 1)
        Severity   = switch ($Celsius) {
            { $_ -ge 90 } { 'CRITICAL'; break }
            { $_ -ge 80 } { 'HOT';      break }
            { $_ -ge 70 } { 'WARM';     break }
            default       { 'OK' }
        }
    }
}

# ---------- providers --------------------------------------------------------

function Get-LhmReadings {
    # Works with LibreHardwareMonitor or legacy OpenHardwareMonitor
    foreach ($ns in 'root/LibreHardwareMonitor', 'root/OpenHardwareMonitor') {
        try {
            $sensors = Get-CimInstance -Namespace $ns -ClassName Sensor `
                -ErrorAction Stop | Where-Object SensorType -eq 'Temperature'
        } catch { continue }

        $hw = Get-CimInstance -Namespace $ns -ClassName Hardware -ErrorAction SilentlyContinue
        foreach ($s in $sensors) {
            $parent = ($hw | Where-Object Identifier -eq $s.Parent | Select-Object -First 1).Name
            New-Reading -Source ($ns -replace '.*/') `
                        -Asset  ($parent ?? 'Unknown') `
                        -Sensor $s.Name `
                        -Celsius $s.Value
        }
    }
}

function Get-NvidiaSmiReadings {
    $smi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $smi) { return }

    $csv = & nvidia-smi --query-gpu=index,name,temperature.gpu `
                       --format=csv,noheader,nounits 2>$null
    foreach ($line in $csv) {
        $parts = $line -split '\s*,\s*'
        if ($parts.Count -ge 3 -and $parts[2] -match '^\d+$') {
            New-Reading -Source 'nvidia-smi' `
                        -Asset  "GPU$($parts[0]) $($parts[1])" `
                        -Sensor 'Core' `
                        -Celsius ([double]$parts[2])
        }
    }
}

function Get-AcpiReadings {
    try {
        $zones = Get-CimInstance -Namespace 'root/WMI' `
            -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop
    } catch {
        Write-Verbose "ACPI thermal zones unavailable: $($_.Exception.Message)"
        return
    }
    foreach ($z in $zones) {
        # CurrentTemperature is in tenths of Kelvin
        $c = ($z.CurrentTemperature / 10) - 273.15
        if ($c -gt 0 -and $c -lt 150) {
            New-Reading -Source 'ACPI' -Asset 'System' `
                        -Sensor ($z.InstanceName -replace '.*\\') `
                        -Celsius $c
        }
    }
}

function Get-StorageReadings {
    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop
    } catch { return }

    foreach ($d in $disks) {
        try {
            $r = $d | Get-StorageReliabilityCounter -ErrorAction Stop
            if ($r.Temperature -and $r.Temperature -gt 0) {
                New-Reading -Source 'StorageReliability' `
                            -Asset  "Disk $($d.DeviceId) $($d.FriendlyName)" `
                            -Sensor 'Drive' `
                            -Celsius ([double]$r.Temperature)
            }
        } catch { }
    }
}

function Get-BatteryReadings {
    try {
        $bats = Get-CimInstance Win32_Battery -ErrorAction Stop
    } catch { return }
    foreach ($b in $bats) {
        # Win32_Battery has no temperature; try the ACPI battery class
        try {
            $bt = Get-CimInstance -Namespace 'root/WMI' `
                -ClassName BatteryTemperature -ErrorAction Stop |
                Where-Object InstanceName -like "*$($b.DeviceID)*"
            foreach ($x in $bt) {
                $c = ($x.Temperature / 10) - 273.15
                New-Reading -Source 'ACPI-Battery' -Asset $b.Name `
                            -Sensor 'Pack' -Celsius $c
            }
        } catch { }
    }
}

# ---------- orchestrator -----------------------------------------------------

function Get-AssetHeat {
    $all = @()
    $all += Get-LhmReadings
    $all += Get-NvidiaSmiReadings
    $all += Get-AcpiReadings
    $all += Get-StorageReadings
    $all += Get-BatteryReadings
    return ,$all
}

function Show-AssetHeat {
    $readings = Get-AssetHeat
    if (-not $readings -or $readings.Count -eq 0) {
        Write-Warning @"
No temperature sensors readable.
  • Run as Administrator.
  • For full coverage install LibreHardwareMonitor:
        winget install LibreHardwareMonitor.LibreHardwareMonitor
    then launch it once with 'Run as admin' so the WMI provider registers.
"@
        return
    }

    if ($Raw) { return $readings }

    # ANSI color per severity (PS 7 supports `$PSStyle`)
    $colored = $readings | Sort-Object Source, Asset, Sensor | ForEach-Object {
        $color = switch ($_.Severity) {
            'CRITICAL' { $PSStyle.Foreground.BrightRed   + $PSStyle.Bold }
            'HOT'      { $PSStyle.Foreground.Red }
            'WARM'     { $PSStyle.Foreground.Yellow }
            default    { $PSStyle.Foreground.Green }
        }
        $_ | Add-Member -NotePropertyName _color -NotePropertyValue $color -PassThru
    }

    Clear-Host
    "Asset Heat — $(Get-Date -Format 's')" | Write-Host -ForegroundColor Cyan
    ('-' * 78)                              | Write-Host -ForegroundColor DarkGray

    $colored | Format-Table -AutoSize @(
        @{ N='Source';     E={ $_.Source } }
        @{ N='Asset';      E={ $_.Asset  } }
        @{ N='Sensor';     E={ $_.Sensor } }
        @{ N='°C';         E={ "$($_._color)$($_.Celsius)$($PSStyle.Reset)" }; A='Right' }
        @{ N='°F';         E={ $_.Fahrenheit }; A='Right' }
        @{ N='Status';     E={ "$($_._color)$($_.Severity)$($PSStyle.Reset)" } }
    )
}

# ---------- entry point ------------------------------------------------------

if ($WatchSeconds -gt 0) {
    while ($true) {
        Show-AssetHeat
        Start-Sleep -Seconds $WatchSeconds
    }
} else {
    Show-AssetHeat
}
