using Toybox.BluetoothLowEnergy;
using Toybox.Lang;
using Toybox.System;

module OctoWatch {

    // Connection state constants
    const BLE_STATE_SCANNING     = 0;
    const BLE_STATE_CONNECTING   = 1;
    const BLE_STATE_SUBSCRIBING  = 2;
    const BLE_STATE_STREAMING    = 3;
    const BLE_STATE_RECONNECTING = 4;
    const BLE_STATE_SIMULATED    = 5;

    // BLE Central Delegate & Auto-Reconnection Manager for Octopus-16
    class OctoBleDelegate extends BluetoothLowEnergy.BleDelegate {

        private var _profileManager;
        private var _ringBuffer;

        private var _bleState;
        private var _device;
        private var _lastScanResult;
        private var _deviceName;
        private var _lastRssi;

        private var _dataChar;
        private var _cmdChar;

        // Auto-reconnect & simulator fallback timers (tracked in ticks from view timer)
        private var _stateTicks;
        private var _reconnectAttempts;
        private var _autoSimFallback;

        // Debounced/queued BLE channel write state so rapid swipes never stall GATT queue
        private var _writeInProgress;
        private var _pendingRemoteCh;
        private var _activeRemoteCh;

        function initialize(profileManager, ringBuffer) {
            BleDelegate.initialize();
            _profileManager = profileManager;
            _ringBuffer = ringBuffer;

            _bleState = BLE_STATE_SCANNING;
            _device = null;
            _lastScanResult = null;
            _deviceName = "Octopus-16";
            _lastRssi = null;
            _dataChar = null;
            _cmdChar = null;
            _stateTicks = 0;
            _reconnectAttempts = 0;
            _autoSimFallback = true;
            _writeInProgress = false;
            _pendingRemoteCh = -1;
            _activeRemoteCh = 0;
        }

        // Start BLE scanning for Octopus-16
        function startScanning() {
            _stateTicks = 0;
            if (_reconnectAttempts > 0) {
                _bleState = BLE_STATE_RECONNECTING;
            } else {
                _bleState = BLE_STATE_SCANNING;
            }
            try {
                BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_SCANNING);
            } catch (e) {
                // Simulator without BLE dongle attached -> stays in scanning briefly then enters Demo 250 SPS
            }
        }

        // Toggle between live BLE scan and 250 SPS Simulator mode (for bench/UI testing)
        function toggleSimulationMode() {
            if (_bleState == BLE_STATE_SIMULATED) {
                _autoSimFallback = false;
                _ringBuffer.reset();
                _reconnectAttempts = 0;
                startScanning();
            } else {
                try {
                    if (_device != null) {
                        BluetoothLowEnergy.unpairDevice(_device);
                        _device = null;
                    }
                    BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
                } catch (e) {}
                _ringBuffer.reset();
                _deviceName = "SIM-Octopus16";
                _bleState = BLE_STATE_SIMULATED;
            }
        }

        // Force a fresh BLE rescan / reconnect
        function forceReconnect() {
            _autoSimFallback = false;
            try {
                if (_device != null) {
                    BluetoothLowEnergy.unpairDevice(_device);
                    _device = null;
                }
                BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
            } catch (e) {}
            _ringBuffer.reset();
            _reconnectAttempts++;
            startScanning();
        }

        // Periodic watchdog called at 4 Hz (every 250ms) from View timer
        function onWatchdogTick(selectedCh) {
            _stateTicks++;

            // Flush any pending channel selection once GATT write queue is free
            flushPendingChannelWrite();

            // In simulated mode, pump lightweight LUT samples for the active bank
            if (_bleState == BLE_STATE_SIMULATED) {
                _ringBuffer.injectSyntheticBatch(selectedCh);
                return;
            }

            // If scanning and no physical Octopus-16 found after 6 seconds (24 ticks @ 250ms)
            // and auto-fallback is enabled (e.g. in Garmin Simulator), switch to 250 SPS Demo stream
            // while still allowing manual BLE scan via Menu/long-press
            if (_bleState == BLE_STATE_SCANNING && _autoSimFallback && _stateTicks > 24) {
                _deviceName = "SIM-Octopus16";
                _bleState = BLE_STATE_SIMULATED;
                return;
            }

            // Watchdog for stalled connection/subscription (>8 seconds): auto-retry
            if ((_bleState == BLE_STATE_CONNECTING || _bleState == BLE_STATE_SUBSCRIBING) && _stateTicks > 32) {
                forceReconnect();
            }
        }

        // BLE Callback: Scan Results
        function onScanResults(scanResults) {
            for (var result = scanResults.next(); result != null; result = scanResults.next()) {
                if (result instanceof BluetoothLowEnergy.ScanResult) {
                    var name = result.getDeviceName();
                    var matchesUuid = hasServiceUuid(result.getServiceUuids(), _profileManager.OCTOPUS_SERVICE_UUID);
                    var matchesName = (name != null && (
                        name.find("Octopus") != null ||
                        name.find("Octopos") != null ||
                        name.find("PiEEG") != null ||
                        name.find("bioron") != null
                    ));

                    if (matchesUuid || matchesName) {
                        if (name != null) {
                            _deviceName = name;
                        }
                        _lastRssi = result.getRssi();
                        _lastScanResult = result;
                        connectToResult(result);
                        return;
                    }
                }
            }
        }

        private function connectToResult(scanResult) {
            _stateTicks = 0;
            _bleState = BLE_STATE_CONNECTING;
            try {
                BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
                _device = BluetoothLowEnergy.pairDevice(scanResult);
            } catch (e) {
                startScanning();
            }
        }

        // BLE Callback: Connection State Changed
        function onConnectedStateChanged(device, state) {
            if (state == BluetoothLowEnergy.CONNECTION_STATE_CONNECTED) {
                _device = device;
                _stateTicks = 0;
                _bleState = BLE_STATE_SUBSCRIBING;
                enableNotifications(device);
            } else {
                // Disconnected -> Automatically reconnect!
                _device = null;
                _dataChar = null;
                _cmdChar = null;
                _writeInProgress = false;
                _pendingRemoteCh = -1;
                _reconnectAttempts++;
                _bleState = BLE_STATE_RECONNECTING;
                _stateTicks = 0;

                // If we have a cached ScanResult, try immediate re-pair or restart scan
                startScanning();
            }
        }

        // Subscribe to Octopus-16 DATA_CHAR_UUID CCCD (0x2902)
        private function enableNotifications(device) {
            try {
                var service = device.getService(_profileManager.OCTOPUS_SERVICE_UUID);
                if (service != null) {
                    _dataChar = service.getCharacteristic(_profileManager.OCTOPUS_DATA_CHAR_UUID);
                    _cmdChar  = service.getCharacteristic(_profileManager.OCTOPUS_CMD_CHAR_UUID);

                    if (_dataChar != null) {
                        var cccd = _dataChar.getDescriptor(BluetoothLowEnergy.cccdUuid());
                        if (cccd != null) {
                            cccd.requestWrite([0x01, 0x00]b);
                            return;
                        }
                    }
                }
            } catch (e) {
                // Fall through to retry
            }
        }

        // BLE Callback: CCCD Descriptor Write Complete
        function onDescriptorWrite(descriptor, status) {
            if (status == BluetoothLowEnergy.STATUS_SUCCESS) {
                _bleState = BLE_STATE_STREAMING;
                _stateTicks = 0;
            } else {
                forceReconnect();
            }
        }

        // BLE Callback: Incoming EEG GATT Notification
        function onCharacteristicChanged(characteristic, value) {
            if (_bleState != BLE_STATE_STREAMING) {
                _bleState = BLE_STATE_STREAMING;
            }
            _stateTicks = 0;
            _ringBuffer.parseBleNotification(value);
        }

        // Send active channel selection [0xC0, ch] to Octopus-16 Garmin firmware
        // Non-blocking & debounced: queues channel and flushes when GATT is idle
        function selectRemoteChannel(ch) {
            _pendingRemoteCh = ch & 0x0F;
            flushPendingChannelWrite();
        }

        private function flushPendingChannelWrite() {
            if (_pendingRemoteCh < 0 || _writeInProgress) {
                return;
            }
            if (_bleState != BLE_STATE_STREAMING || _cmdChar == null) {
                _pendingRemoteCh = -1;
                return;
            }
            var ch = _pendingRemoteCh;
            if (ch == _activeRemoteCh) {
                _pendingRemoteCh = -1;
                return;
            }
            try {
                var payload = [0xC0, (ch & 0x0F)]b;
                _writeInProgress = true;
                _pendingRemoteCh = -1;
                _cmdChar.requestWrite(payload, {:writeType => BluetoothLowEnergy.WRITE_TYPE_DEFAULT});
                _activeRemoteCh = ch;
            } catch (e) {
                _writeInProgress = false;
                _pendingRemoteCh = ch;
            }
        }

        function onCharacteristicWrite(characteristic, status) {
            _writeInProgress = false;
            flushPendingChannelWrite();
        }

        private function hasServiceUuid(iter, targetUuid) {
            if (iter == null) {
                return false;
            }
            for (var uuid = iter.next(); uuid != null; uuid = iter.next()) {
                if (uuid.equals(targetUuid)) {
                    return true;
                }
            }
            return false;
        }

        // Getters for UI
        function getBleState() { return _bleState; }
        function getDeviceName() { return _deviceName; }
        function getLastRssi() { return _lastRssi; }
        function getReconnectAttempts() { return _reconnectAttempts; }

        function getStateLabel() {
            if (_bleState == BLE_STATE_STREAMING)    { return "BLE LIVE"; }
            if (_bleState == BLE_STATE_SIMULATED)    { return "SIM 250Hz"; }
            if (_bleState == BLE_STATE_RECONNECTING) { return "RECONNECT"; }
            if (_bleState == BLE_STATE_CONNECTING)   { return "PAIRING"; }
            if (_bleState == BLE_STATE_SUBSCRIBING)  { return "GATT SUB"; }
            return "SCANNING";
        }
    }
}
