# octoWatch — Garmin Connect IQ EEG Monitor for PiEEG Octopus-16

**[Download octoWatch on Garmin Connect IQ Store →](https://apps.garmin.com/apps/8e994535-c853-45ca-abe3-ccef61119c8b)**

**octoWatch** is a Garmin Connect IQ watch application that decodes and visualizes 16-channel 250 SPS biosignals in real time over Bluetooth Low Energy (BLE) from the **PiEEG Octopus-16** (ESP32-S3 + dual Texas Instruments `ADS131M08` 24-bit delta-sigma ADCs).

---

## Features

- **Direct BLE GATT Streaming (`Toybox.BluetoothLowEnergy`)**
  - Automatically scans for, pairs with, and subscribes to the Octopus-16 BLE GATT service.
  - Built-in connection watchdog and automatic reconnection on link drop.
  - **250 SPS Synthetic Simulator Mode**: Automatically activates after 6 seconds in the Garmin Simulator (or when no BLE device is in range), generating realistic 16-channel synthetic EEG (`10 Hz` Alpha, `22 Hz` Beta, `5 Hz` Theta, plus periodic frontal blink artifacts on `Fp1`/`Fp2`).
- **Dual BLE Packet Framing Support**
  - **Standard 51-Byte Frame (`0xA0 ... 0xC0`)**: Full 16-channel × 24-bit signed big-endian samples from ADC1 (`CH01–CH08`) and ADC2 (`CH09–CH16`), including multi-frame notifications (`N × 51` bytes).
  - **Compact Batched Frame (`0xA1`)**: Low-MTU (20-byte) batched `int16` frame (`0.1 µV` resolution) for constrained Garmin BLE links.
- **On-Watch Signal Processing**
  - Zero-allocation 16-channel × 128-sample (`~0.51 s` window at 250 SPS) circular ring buffer.
  - Per-channel online IIR DC-blocking high-pass filter ($\alpha = 0.992$) to keep waveforms centered without baseline drift.
  - Real-time 64-sample RMS amplitude ($\mu\text{V}$), measured sampling rate (`SPS`), packet drop tracking, and composite Signal Quality Index (`SQI%`).
- **Three Interactive Display Views (20 FPS UI)**
  1. **`1CH` — Single-Channel 250 SPS Oscilloscope**: High-precision live trace with playhead, graticule, $\mu\text{V}$, and RMS readout (`CH01`–`CH16`, mapped to 10–20 labels `Fp1`..`P8`).
  2. **`4CH` — 4-Channel Stacked Montage**: Simultaneous 4-channel bank display around the selected channel.
  3. **`16CH` — Full 16-Channel Activity & Quality Matrix**: 4×4 electrode grid color-coded by SQI and RMS activity, with live packet (`PKT`) and drop (`DROP`) counters.

---

## Repository Structure

```text
octoWatch/
├── manifest.xml                       # Connect IQ app manifest (minSdkVersion 3.2.0, BLE permission)
├── monkey.jungle                      # Monkey C build configuration
├── developer_key                      # Developer RSA key for signing Connect IQ builds
├── resources/
│   ├── drawables.xml                  # Launcher icon resource definition
│   ├── launcher_icon.png              # Watch app launcher icon
│   └── strings.xml                    # App name string resources
├── source/
│   ├── OctoWatchApp.mc                # Application entry point & lifecycle management
│   ├── OctoProfileManager.mc          # BLE GATT profile & UUID registration
│   ├── OctoBleDelegate.mc             # BLE scan, pairing, CCCD subscription & watchdog
│   ├── EegRingBuffer.mc               # 16-ch ring buffer, 51B/0xA1 decoders, DC filter & 250Hz synth
│   ├── OctoWatchView.mc               # 20 FPS renderer (1CH scope, 4CH montage, 16CH matrix)
│   └── OctoWatchDelegate.mc           # Button & touch input handling
└── firmware/
    └── OCTOPUS-16-GARMIN/
        ├── dev.ps1                    # Firmware build, flash, monitor, scan & capture helper
        ├── ESP32/
        │   ├── ESP32.ino              # Garmin-optimized BLE EEG firmware (defaults to 20B 0xA1 batch mode)
        │   ├── ADS131M08.h            # TI ADS131M08 8-channel 24-bit ADC register map & class header
        │   └── ADS131M08.cpp          # ESP32 SPI/DMA driver for ADS131M08 (1 MHz, SPI_MODE1)
        ├── ble_scan.py                # Python Bleak scanner to locate Octopus-16 BLE advertisements
        ├── ble_capture.py             # End-to-end BLE capture & decoder for 0xA1 (20B) and 0xA0 (51B)
        └── monitor.py                 # Non-resetting serial monitor for XIAO ESP32-S3 USB CDC
```

---

## BLE Protocol & ADC Scaling

### GATT Profile UUIDs
| Resource | UUID | Properties |
| :--- | :--- | :--- |
| **Octopus Service** | `4fafc201-1fb5-459e-8fcc-c5c9c331914b` | Primary Service |
| **EEG Data Characteristic** | `beb5483e-36e1-4688-b7f5-ea07361b26a8` | `NOTIFY` (CCCD `0x2902`) |
| **Command Characteristic** | `c0de0001-36e1-4688-b7f5-ea07361b26a8` | `WRITE` |

*(Scanner also matches device names containing `Octopus`, `Octopos`, `PiEEG`, or `bioron`.)*

### Frame Formats
1. **Standard 51-Byte Frame (`0xA0`)**
   - `Byte [0]`: `0xA0` (Start Marker)
   - `Byte [1]`: `seq` (8-bit rolling sample counter `0..255`)
   - `Bytes [2..25]`: ADC1 Channels `0..7` (8 × 3-byte big-endian signed 24-bit integers)
   - `Bytes [26..49]`: ADC2 Channels `8..15` (8 × 3-byte big-endian signed 24-bit integers)
   - `Byte [50]`: `0xC0` (End Marker)
2. **Compact Batched Frame (`0xA1`)**
   - `Byte [0]`: `0xA1` (Batch Start Marker)
   - `Byte [1]`: First sample sequence counter (`0..255`)
   - `Byte [2]`: Target channel ID (`0..15`)
   - `Byte [3]`: Sample count `K` (e.g. `K = 8` fits in a 20-byte BLE MTU payload)
   - `Bytes [4..4+2K-1]`: `K` × big-endian signed 16-bit samples in `0.1 µV` units

### ADS131M08 Conversion Formula
With $V_{\text{REF}} = 1.2\text{ V}$, $\text{PGA} = 4$, and 24-bit two's complement output ($2^{23} - 1 = 8{,}388{,}607$):

$$\text{LSB} = \frac{1.2\text{ V} / 4}{8{,}388{,}607} \times 10^6 \approx 0.03576279\ \mu\text{V/LSB}$$

### 10–20 Electrode Channel Mapping
| Index | Label | Index | Label | Index | Label | Index | Label |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **CH01** | `Fp1` | **CH05** | `C3` | **CH09** | `O1` | **CH13** | `T7` |
| **CH02** | `Fp2` | **CH06** | `C4` | **CH10** | `O2` | **CH14** | `T8` |
| **CH03** | `F3`  | **CH07** | `P3` | **CH11** | `F7` | **CH15** | `P7` |
| **CH04** | `F4`  | **CH08** | `P4` | **CH12** | `F8` | **CH16** | `P8` |

---

## Watch Controls

| Input / Gesture | Action |
| :--- | :--- |
| **Select / Tap Screen** | Cycle display mode: `1CH` Scope $\rightarrow$ `4CH` Montage $\rightarrow$ `16CH` Matrix |
| **Up / Swipe Up (Next Page)** | Select next EEG channel (`CH01` $\rightarrow$ `CH16`) |
| **Down / Swipe Down (Prev Page)** | Select previous EEG channel (`CH16` $\rightarrow$ `CH01`) |
| **Menu / Long-Press Up** | Toggle between **Live BLE Scan** and **250 SPS Simulator Mode** |
| **Back** | Exit application |

---

## Developer Scripts & VS Code Tasks

### Unified Developer CLI (`.\dev.ps1`)
From the repository root, use `.\dev.ps1` to build, flash, monitor, and test both the ESP32-S3 firmware and the Garmin Connect IQ watch app:

```powershell
.\dev.ps1 fw-flash-monitor    # Compile & flash Octopus-16 Garmin firmware + monitor COM port
.\dev.ps1 fw-build            # Compile ESP32-S3 Garmin firmware only
.\dev.ps1 fw-flash            # Flash ESP32-S3 Garmin firmware (auto-detects COM port)
.\dev.ps1 fw-monitor          # Monitor ESP32-S3 USB CDC logs (without DTR/RTS reset)
.\dev.ps1 ble-scan            # Scan for Octopus-16 BLE advertisement
.\dev.ps1 ble-capture         # Connect over BLE & verify 250 SPS 0xA1 20-byte batched stream
.\dev.ps1 watch-build         # Compile Garmin Connect IQ watch app (bin\octoWatch.prg)
.\dev.ps1 watch-sim           # Build & launch octoWatch.prg in Garmin Simulator (Venu 3)
.\dev.ps1 all                 # Flash ESP32-S3 + build & launch Garmin Simulator
```

*(You can also run these directly from VS Code via **Terminal → Run Task...** defined in [.vscode/tasks.json](./.vscode/tasks.json), or invoke [firmware/OCTOPUS-16-GARMIN/dev.ps1](./firmware/OCTOPUS-16-GARMIN/dev.ps1) directly.)*

---

## Building & Running in the Garmin Simulator

### Prerequisites
- [Garmin Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) (SDK 8.x+ recommended; minimum target API 3.2.0)
- Visual Studio Code with the **Monkey C** extension (optional)

### Compile `.prg` Binary (PowerShell)
```powershell
$sdkBin = "$env:APPDATA\Garmin\ConnectIQ\Sdks\connectiq-sdk-win-8.4.0-2025-12-03-5122605dc\bin"

& "$sdkBin\monkeyc.bat" `
  -d venu3 `
  -f monkey.jungle `
  -o bin\octoWatch.prg `
  -y developer_key
```

### Launch Simulator & Run App
```powershell
# 1. Start the Connect IQ Simulator
Start-Process "$sdkBin\simulator.exe"

# 2. Push and launch the compiled binary on Venu 3
& "$sdkBin\monkeydo.bat" bin\octoWatch.prg venu3
```

---

## Supported Garmin Devices

Declared in [manifest.xml](./manifest.xml):
- **Venu Series**: Venu, Venu 2 / 2s / 2 Plus, Venu 3 / 3s, Venu Sq / Sq M / Sq 2 / Sq 2 Music
- **vívoactive Series**: vívoactive 4 / 4s, vívoactive 5
- **fēnix Series**: fēnix 6 / 6s / 6 Pro / 6s Pro / 6X Pro, fēnix 7 / 7s / 7X / Pro variants, fēnix 8 (43mm / 47mm / Solar 47mm / Solar 51mm)
- **epix Series**: epix (Gen 2), epix Pro (42mm / 47mm / 51mm)
- **Forerunner Series**: FR 165 / 165 Music, FR 245 / 245 Music, FR 255 / 255s / Music, FR 265 / 265s, FR 745, FR 945, FR 955, FR 965

---

## Firmware

You can flash Octopus-16 for garmin here:
https://biocircuit.pieeg.com/flash