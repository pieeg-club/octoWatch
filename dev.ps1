<#
octoWatch Unified Developer CLI (Garmin Watch App + Octopus-16 ESP32-S3 Firmware)

Usage:
  .\dev.ps1 watch-build                 # Compile Garmin Connect IQ app (bin\octoWatch.prg)
  .\dev.ps1 watch-install               # Build & install octoWatch.prg directly to USB-connected Garmin Venu
  .\dev.ps1 watch-iq                    # Export signed Garmin Connect IQ Store package (bin\octoWatch.iq)
  .\dev.ps1 watch-sim                   # Build & launch in Garmin Connect IQ Simulator (venu3)
  .\dev.ps1 fw-build                    # Compile Octopus-16 Garmin ESP32-S3 firmware
  .\dev.ps1 fw-flash                    # Compile & flash Octopus-16 ESP32-S3 over USB
  .\dev.ps1 fw-monitor                  # Monitor ESP32-S3 USB CDC serial logs (no DTR/RTS reset)
  .\dev.ps1 fw-flash-monitor            # Compile, flash, and monitor ESP32-S3
  .\dev.ps1 ble-scan                    # Scan for Octopus-16 BLE advertisement
  .\dev.ps1 ble-capture                 # Subscribe to Octopus-16 BLE & verify 250 SPS 0xA1 packets
  .\dev.ps1 all                         # Flash ESP32-S3 firmware + build & run Garmin watch simulator

Options:
  -Device venu                          # Garmin target device ID (default: venu)
  -Port COM3                            # ESP32-S3 serial port (auto-detected if omitted)
  -Seconds 8                            # Duration for monitor / BLE scan / capture
#>
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'watch-build',
        'watch-install',
        'watch-iq',
        'watch-sim',
        'fw-build',
        'fw-flash',
        'fw-monitor',
        'fw-flash-monitor',
        'ble-scan',
        'ble-capture',
        'all'
    )]
    [string]$Cmd = 'watch-sim',
    [string]$Device = 'venu',
    [string]$Port = '',
    [int]$Seconds = 8
)

$ErrorActionPreference = 'Stop'

$RepoRoot = $PSScriptRoot
$FwScript = Join-Path $RepoRoot 'firmware\OCTOPUS-16-GARMIN\dev.ps1'

function Resolve-GarminSdkBin {
    $cfg = Join-Path $env:APPDATA 'Garmin\ConnectIQ\current-sdk.cfg'
    if (Test-Path $cfg) {
        $sdkRoot = (Get-Content $cfg -Raw).Trim()
        $bin = Join-Path $sdkRoot 'bin'
        if (Test-Path $bin) { return $bin }
    }
    $sdksDir = Join-Path $env:APPDATA 'Garmin\ConnectIQ\Sdks'
    if (Test-Path $sdksDir) {
        $latest = Get-ChildItem $sdksDir -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { return (Join-Path $latest.FullName 'bin') }
    }
    throw "Garmin Connect IQ SDK not found under $env:APPDATA\Garmin\ConnectIQ"
}

function Invoke-WatchBuild {
    $sdkBin = Resolve-GarminSdkBin
    $monkeyc = Join-Path $sdkBin 'monkeyc.bat'
    $jungle  = Join-Path $RepoRoot 'monkey.jungle'
    $outPrg  = Join-Path $RepoRoot 'bin\octoWatch.prg'
    $devKey  = Join-Path $RepoRoot 'developer_key'

    Write-Host "--- Building octoWatch.prg for device '$Device' ---" -ForegroundColor Cyan
    & $monkeyc -d $Device -f $jungle -o $outPrg -y $devKey
    if ($LASTEXITCODE -ne 0) { throw "Garmin watch build failed with exit code $LASTEXITCODE" }
    Write-Host "--- Built: $outPrg ---" -ForegroundColor Green
}

function Invoke-WatchSim {
    Invoke-WatchBuild
    $sdkBin   = Resolve-GarminSdkBin
    $simExe   = Join-Path $sdkBin 'simulator.exe'
    $monkeydo = Join-Path $sdkBin 'monkeydo.bat'
    $outPrg   = Join-Path $RepoRoot 'bin\octoWatch.prg'

    $running = Get-Process -Name 'simulator*' -ErrorAction SilentlyContinue
    if (-not $running) {
        Write-Host "--- Starting Garmin Connect IQ Simulator ---" -ForegroundColor Cyan
        Start-Process -FilePath $simExe
        Start-Sleep -Seconds 3
    }
    Write-Host "--- Launching octoWatch.prg on '$Device' in Simulator ---" -ForegroundColor Cyan
    Start-Process -FilePath $monkeydo -ArgumentList @("`"$outPrg`"", $Device) -WindowStyle Hidden
}

function Invoke-WatchIq {
    $sdkBin = Resolve-GarminSdkBin
    $monkeyc = Join-Path $sdkBin 'monkeyc.bat'
    $jungle  = Join-Path $RepoRoot 'monkey.jungle'
    $outIq   = Join-Path $RepoRoot 'bin\octoWatch.iq'
    $devKey  = Join-Path $RepoRoot 'developer_key'

    Write-Host "--- Exporting signed Garmin Connect IQ Store package (bin\octoWatch.iq) ---" -ForegroundColor Cyan
    & $monkeyc -e -r -f $jungle -o $outIq -y $devKey
    if ($LASTEXITCODE -ne 0) { throw "Garmin IQ package export failed with exit code $LASTEXITCODE" }
    Write-Host "--- Exported Store Package: $outIq ---" -ForegroundColor Green
}

function Invoke-WatchInstall {
    Invoke-WatchBuild
    Write-Host "--- Installing bin\octoWatch.prg onto USB-connected Garmin watch (GARMIN\APPS) ---" -ForegroundColor Cyan
    $shell = New-Object -ComObject Shell.Application
    $pc = $shell.NameSpace(17)
    $watch = $pc.Items() | Where-Object { $_.Name -match 'Venu|Garmin|Fenix|Forerunner|Epix| Approach' } | Select-Object -First 1
    if (-not $watch) { throw "No USB-connected Garmin MTP watch found. Make sure it is plugged in." }
    $storage = $watch.GetFolder.Items() | Select-Object -First 1
    $garmin  = $storage.GetFolder.Items() | Where-Object { $_.Name -ieq 'GARMIN' } | Select-Object -First 1
    $apps    = $garmin.GetFolder.Items()  | Where-Object { $_.Name -ieq 'APPS' }   | Select-Object -First 1

    $binFolder = $shell.NameSpace((Join-Path $RepoRoot 'bin'))
    $prgItem   = $binFolder.ParseName('octoWatch.prg')
    $apps.GetFolder.CopyHere($prgItem, 20)
    Start-Sleep -Seconds 2
    Write-Host "--- Installed octoWatch.prg onto $($watch.Name)\GARMIN\APPS! Unplug USB to launch. ---" -ForegroundColor Green
}

switch ($Cmd) {
    'watch-build'      { Invoke-WatchBuild }
    'watch-install'    { Invoke-WatchInstall }
    'watch-iq'         { Invoke-WatchIq }
    'watch-sim'        { Invoke-WatchSim }
    'fw-build'         { & $FwScript build -Port $Port -MonitorSeconds $Seconds }
    'fw-flash'         { & $FwScript flash -Port $Port -MonitorSeconds $Seconds }
    'fw-monitor'       { & $FwScript monitor -Port $Port -MonitorSeconds $Seconds }
    'fw-flash-monitor' { & $FwScript flash-monitor -Port $Port -MonitorSeconds $Seconds }
    'ble-scan'         { & $FwScript scan -Port $Port -MonitorSeconds $Seconds }
    'ble-capture'      { & $FwScript capture -Port $Port -MonitorSeconds $Seconds }
    'all'              {
        & $FwScript flash-monitor -Port $Port -MonitorSeconds $Seconds
        Invoke-WatchSim
    }
}
