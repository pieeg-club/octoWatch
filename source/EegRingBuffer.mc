using Toybox.Math;
using Toybox.System;

module OctoWatch {

    // High-throughput, zero-allocation EEG Ring Buffer & Packet Decoder for Octopus-16
    //
    // Supports two BLE framing formats from Octopus-16 (ESP32-S3 + dual ADS131M08):
    //
    // 1. Standard 51-byte frame (1 sample x 16 channels, 24-bit signed BE):
    //    [0]      = 0xA0 (START_MARKER)
    //    [1]      = sample counter (0..255)
    //    [2..25]  = ADC1 ch 0..7  (8 x 3-byte big-endian signed 24-bit)
    //    [26..49] = ADC2 ch 8..15 (8 x 3-byte big-endian signed 24-bit)
    //    [50]     = 0xC0 (END_MARKER)
    //     Can be concatenated: N * 51 bytes per notification (e.g., 4x51 = 204B)
    //
    // 2. Compact Batched 0xA1 frame (for Garmin 20-byte / low-MTU BLE links):
    //    [0]      = 0xA1 (BATCH_START_MARKER)
    //    [1]      = first sample counter (0..255)
    //    [2]      = channelId (0..15) or 0xFF (multi-channel int16)
    //    [3]      = sampleCount (K samples, e.g., K=8 fits in 20 bytes: 4 + 8*2 = 20B)
    //    [4..4+2K-1] = K x big-endian signed 16-bit µV*10 (0.1 µV resolution)
    //
    class EegRingBuffer {

        public const NUM_CHANNELS = 16;
        public const BUFFER_SIZE = 128; // Circular waveform buffer

        // Protocol constants
        private const START_MARKER = 0xA0;
        private const BATCH_MARKER = 0xA1;
        private const SMART_MARKER = 0xA2;
        private const END_MARKER   = 0xC0;
        private const PACKET_SIZE  = 51;
        private const DATA_OFFSET  = 2;
        private const BYTES_PER_CH = 3;

        // ADS131M08 scale: (1.2 / 4.0 / 8388607.0) * 1_000_000 = 0.03576279113 µV / LSB
        private const UV_SCALE = 0.03576279;
        private const SIGN_BIT = 0x800000;
        private const FULL_SCALE_PLUS_ONE = 0x1000000;

        // Circular buffers: 16 channels x 128 samples (stored in integer tenths of µV or µV float)
        private var channelBuffers;
        private var writeIndex;
        private var sampleCountTotal;

        // Latest sample across all 16 channels (for overview / multi-channel grid & RMS)
        private var latestUv;
        private var dcOffsetUv; // High-pass IIR baseline tracker per channel
        private var meanSqUv;   // Running IIR mean-square amplitude per channel
        private var cachedRmsUv;
        private var cachedSqi;
        private var cachedBands;
        private var lastBandCh;
        private var lastMetricsUpdateMs;

        // Telemetry & Signal Quality counters
        private var lastSeqCounter;
        private var packetsReceived;
        private var samplesReceived;
        private var droppedSamples;
        private var lastRateCalcMs;
        private var samplesSinceLastCalc;
        private var packetsSinceLastCalc;
        private var measuredSps;
        private var measuredPps;

        // Synthetic EEG generator state (fast 32-point sine LUT for zero-lag 250 SPS sim)
        private var simStep;
        private var simCounter;
        private var sinLut;

        function initialize() {
            channelBuffers = new [NUM_CHANNELS];
            for (var ch = 0; ch < NUM_CHANNELS; ch++) {
                var buf = new [BUFFER_SIZE];
                for (var i = 0; i < BUFFER_SIZE; i++) {
                    buf[i] = 0.0;
                }
                channelBuffers[ch] = buf;
            }

            latestUv = new [NUM_CHANNELS];
            dcOffsetUv = new [NUM_CHANNELS];
            meanSqUv = new [NUM_CHANNELS];
            cachedRmsUv = new [NUM_CHANNELS];
            cachedSqi = new [NUM_CHANNELS];
            for (var ch = 0; ch < NUM_CHANNELS; ch++) {
                latestUv[ch] = 0.0;
                dcOffsetUv[ch] = 0.0;
                meanSqUv[ch] = 0.0;
                cachedRmsUv[ch] = 0.0;
                cachedSqi[ch] = 0;
            }
            cachedBands = [28, 46, 26];
            lastBandCh = -1;
            lastMetricsUpdateMs = 0;

            // Precompute 32-entry sine lookup table (scaled x1000) once at startup
            sinLut = [
                0, 195, 383, 556, 707, 831, 924, 981,
                1000, 981, 924, 831, 707, 556, 383, 195,
                0, -195, -383, -556, -707, -831, -924, -981,
                -1000, -981, -924, -831, -707, -556, -383, -195
            ];

            writeIndex = 0;
            sampleCountTotal = 0;
            lastSeqCounter = null;
            packetsReceived = 0;
            samplesReceived = 0;
            droppedSamples = 0;
            lastRateCalcMs = System.getTimer();
            samplesSinceLastCalc = 0;
            packetsSinceLastCalc = 0;
            measuredSps = 0;
            measuredPps = 0;
            simStep = 0;
            simCounter = 0;
        }

        // Parse incoming BLE notification ByteArray
        // Supports:
        //  - Single 51-byte Octopus-16 packet (0xA0 ... 0xC0)
        //  - Batched N x 51-byte Octopus-16 packets in one notification
        //  - Compact 20-byte batched packet (0xA1 [seq] [ch] [count] [int16 BE...])
        function parseBleNotification(bytes) {
            if (bytes == null) {
                return 0;
            }
            var len = bytes.size();
            if (len < 6) {
                return 0;
            }

            packetsReceived++;
            packetsSinceLastCalc++;

            var parsedSamples = 0;

            // Format 0: Garmin Smart Edge 0xA2 frame (20 bytes @ 5 Hz — all DSP computed on ESP32-S3!)
            if (bytes[0] == SMART_MARKER && len >= 20) {
                parsedSamples = decodeSmartEdgeFrame(bytes);
                return parsedSamples;
            }
            // Format A: Standard 51-byte Octopus-16 frames (or batched N * 51B)
            else if (bytes[0] == START_MARKER && len >= PACKET_SIZE) {
                var base = 0;
                while (base + PACKET_SIZE <= len) {
                    if (bytes[base] != START_MARKER || bytes[base + PACKET_SIZE - 1] != END_MARKER) {
                        break;
                    }
                    decodeStandard51ByteFrame(bytes, base);
                    parsedSamples++;
                    base += PACKET_SIZE;
                }
            }
            // Format B: Compact 0xA1 Batched single/subset channel frames (fits 20-byte BLE MTU)
            else if (bytes[0] == BATCH_MARKER && len >= 6) {
                parsedSamples = decodeCompactBatchFrame(bytes, len);
            }

            updateRateTelemetry();
            return parsedSamples;
        }

        // Ultra-fast integer-only decoder for 0xA2 Smart Edge Frame (20 bytes @ 5 Hz from ESP32-S3)
        // Zero floating-point math on the watch!
        private function decodeSmartEdgeFrame(bytes) {
            var seq = bytes[1] & 0xFF;
            trackSequenceCounter(seq, 1);

            var targetCh = bytes[2] & 0x0F;
            var sqiPct   = bytes[3] & 0xFF;
            var rmsInt   = bytes[4] & 0xFF;
            var alphaPct = bytes[5] & 0xFF;
            var betaPct  = bytes[6] & 0xFF;
            var thetaPct = bytes[7] & 0xFF;
            var sqiMask  = ((bytes[8] & 0xFF) << 8) | (bytes[9] & 0xFF);

            // Update all 16 channels SQI from the ESP32 16-bit contact quality mask
            for (var c = 0; c < NUM_CHANNELS; c++) {
                if ((sqiMask & (1 << c)) != 0) {
                    cachedSqi[c] = 92;
                    if (cachedRmsUv[c] < 5.0) { cachedRmsUv[c] = 16.0; }
                } else {
                    cachedSqi[c] = 45;
                }
            }
            cachedSqi[targetCh]   = sqiPct;
            cachedRmsUv[targetCh] = rmsInt * 1.0;
            cachedBands           = [thetaPct, alphaPct, betaPct];
            lastBandCh            = targetCh;

            // Unpack 10 pre-scaled int8 waveform samples (-127..+127 uV) into circular buffer
            // Each 50 SPS point is written x2 to keep the 128-point scope smooth
            var targetBuf = channelBuffers[targetCh];
            var wIdx = writeIndex;
            var lastVal = 0.0;
            for (var i = 0; i < 10; i++) {
                var b = bytes[10 + i] & 0xFF;
                if (b >= 128) { b -= 256; }
                lastVal = b * 1.0;
                targetBuf[wIdx] = lastVal;
                wIdx = (wIdx + 1) & 127;
                targetBuf[wIdx] = lastVal;
                wIdx = (wIdx + 1) & 127;
            }
            latestUv[targetCh] = lastVal;
            writeIndex = wIdx;

            // 10 decimated samples represent 50 native 250-SPS samples (200 ms)
            sampleCountTotal += 20;
            samplesReceived += 50;
            samplesSinceLastCalc += 50;
            measuredSps = 250;
            return 50;
        }

        // Decode one 51-byte Octopus-16 frame at offset `base`
        private function decodeStandard51ByteFrame(bytes, base) {
            var seq = bytes[base + 1] & 0xFF;
            trackSequenceCounter(seq, 1);

            var idx = writeIndex;
            for (var ch = 0; ch < NUM_CHANNELS; ch++) {
                var p = base + DATA_OFFSET + (ch * BYTES_PER_CH);
                var raw = (bytes[p] << 16) | (bytes[p + 1] << 8) | bytes[p + 2];
                if (raw >= SIGN_BIT) {
                    raw -= FULL_SCALE_PLUS_ONE;
                }
                var uv = raw * UV_SCALE;

                // Online DC blocker (IIR alpha = 0.992) to keep waveform centered on screen
                var dc = dcOffsetUv[ch] * 0.992 + uv * 0.008;
                dcOffsetUv[ch] = dc;
                var acUv = uv - dc;

                latestUv[ch] = acUv;
                channelBuffers[ch][idx] = acUv;
                meanSqUv[ch] = (meanSqUv[ch] * 0.96) + (acUv * acUv * 0.04);
            }

            writeIndex = (idx + 1) % BUFFER_SIZE;
            sampleCountTotal++;
            samplesReceived++;
            samplesSinceLastCalc++;
        }

        // Decode compact 0xA1 batched packet (e.g. 8 samples x 2 bytes + 4 header = 20 bytes)
        private function decodeCompactBatchFrame(bytes, len) {
            var seq = bytes[1] & 0xFF;
            var targetCh = bytes[2] & 0xFF;
            var count = bytes[3] & 0xFF;
            if (targetCh >= NUM_CHANNELS) {
                targetCh = 0;
            }
            trackSequenceCounter(seq, count);

            var offset = 4;
            var decoded = 0;
            var targetBuf = channelBuffers[targetCh];
            var dc = dcOffsetUv[targetCh];
            var msq = meanSqUv[targetCh];
            var wIdx = writeIndex;
            var lastAc = latestUv[targetCh];

            while (decoded < count && (offset + 1) < len) {
                var raw16 = (bytes[offset] << 8) | bytes[offset + 1];
                if (raw16 >= 0x8000) {
                    raw16 -= 0x10000;
                }
                // Stored in 0.1 µV units -> convert to µV
                var uv = raw16 * 0.1;
                dc = dc * 0.992 + uv * 0.008;
                var acUv = uv - dc;

                lastAc = acUv;
                targetBuf[wIdx] = acUv;
                msq = (msq * 0.96) + (acUv * acUv * 0.04);

                wIdx = (wIdx + 1) % BUFFER_SIZE;
                decoded++;
                offset += 2;
            }

            dcOffsetUv[targetCh] = dc;
            meanSqUv[targetCh] = msq;
            latestUv[targetCh] = lastAc;
            writeIndex = wIdx;
            sampleCountTotal += decoded;
            samplesReceived += decoded;
            samplesSinceLastCalc += decoded;
            return decoded;
        }

        private function trackSequenceCounter(seq, step) {
            if (lastSeqCounter != null) {
                var expected = (lastSeqCounter + step) & 0xFF;
                if (seq != expected) {
                    var gap = (seq - lastSeqCounter) & 0xFF;
                    if (gap > step && gap < 128) {
                        droppedSamples += (gap - step);
                    }
                }
            }
            lastSeqCounter = seq;
        }

        // Ultra-lightweight synthetic batch for Demo / Offline mode (called at 4 Hz = every 250ms)
        // Generates only 12 samples for the 4 active bank channels using integer LUT (~10x fewer ops!)
        function injectSyntheticBatch(activeCh) {
            packetsReceived++;
            packetsSinceLastCalc++;

            var lut = sinLut;
            var wIdx = writeIndex;
            var baseBank = (activeCh / 4) * 4;

            for (var s = 0; s < 12; s++) {
                simStep++;
                var step = simStep;
                var aBase = (step * 3) & 31;
                var bBase = (step * 7) & 31;

                // Only populate the 4 channels in the currently viewed bank
                for (var lane = 0; lane < 4; lane++) {
                    var ch = (baseBank + lane) & 15;
                    var chPhase = ch * 2;
                    var uv = (lut[(aBase + chPhase) & 31] * 24 + lut[(bBase + chPhase) & 31] * 8) / 1000.0;
                    latestUv[ch] = uv;
                    channelBuffers[ch][wIdx] = uv;
                }
                wIdx = (wIdx + 1) & 127;
            }

            writeIndex = wIdx;
            sampleCountTotal += 12;
            samplesReceived += 62;
            samplesSinceLastCalc += 62;
            measuredSps = 250;

            // Keep static O(1) telemetry populated for all 16 channels with zero loops/sqrt
            if (cachedSqi[0] == 0) {
                for (var c = 0; c < NUM_CHANNELS; c++) {
                    cachedRmsUv[c] = 18.5 + (c & 3) * 1.5;
                    cachedSqi[c] = 94 - (c & 3) * 2;
                }
            }
            cachedBands = [26, 48, 26];
            lastBandCh = activeCh;
        }

        // Update measured SPS, packets/sec, and cached RMS/SQI telemetry
        function updateRateTelemetry() {
            var now = System.getTimer();

            // Refresh cached RMS & SQI at most every 250 ms (4 Hz) instead of inside onUpdate()
            if ((now - lastMetricsUpdateMs) >= 250 && samplesReceived > 0) {
                lastMetricsUpdateMs = now;
                var totalExpected = samplesReceived + droppedSamples;
                var deliveryScore = 100;
                if (totalExpected > 0) {
                    deliveryScore = ((samplesReceived * 100) / totalExpected).toNumber();
                }

                for (var ch = 0; ch < NUM_CHANNELS; ch++) {
                    var rms = Math.sqrt(meanSqUv[ch]);
                    cachedRmsUv[ch] = rms;

                    var rmsScore = 100;
                    if (rms < 0.5) {
                        rmsScore = 40;
                    } else if (rms > 350.0) {
                        rmsScore = 30;
                    } else if (rms > 180.0) {
                        rmsScore = 70;
                    }

                    var q = ((rmsScore * 40) + (deliveryScore * 60)) / 100;
                    if (q > 100) { q = 100; }
                    if (q < 0) { q = 0; }
                    cachedSqi[ch] = q;
                }
                lastBandCh = -1; // mark band cache dirty
            }

            var elapsed = now - lastRateCalcMs;
            if (elapsed >= 1000) {
                measuredSps = ((samplesSinceLastCalc * 1000.0) / elapsed).toNumber();
                measuredPps = ((packetsSinceLastCalc * 1000.0) / elapsed).toNumber();
                samplesSinceLastCalc = 0;
                packetsSinceLastCalc = 0;
                lastRateCalcMs = now;
            }
        }

        // Get circular buffer array and current write head for fast rendering
        function getChannelBuffer(ch) {
            if (ch < 0 || ch >= NUM_CHANNELS) {
                return channelBuffers[0];
            }
            return channelBuffers[ch];
        }

        function getWriteIndex() {
            return writeIndex;
        }

        function getLatestUv(ch) {
            if (ch < 0 || ch >= NUM_CHANNELS) {
                return 0.0;
            }
            return latestUv[ch];
        }

        // O(1) cached RMS amplitude (µV) lookup — zero loops inside onUpdate()
        function getChannelRmsUv(ch) {
            if (sampleCountTotal == 0 || ch < 0 || ch >= NUM_CHANNELS) {
                return 0.0;
            }
            return cachedRmsUv[ch];
        }

        // O(1) cached Signal Quality 0..100% lookup — zero loops inside onUpdate()
        function getSignalQualityPercent(ch) {
            if (samplesReceived == 0 || ch < 0 || ch >= NUM_CHANNELS) {
                return 0;
            }
            return cachedSqi[ch];
        }

        // Cached EEG spectral band estimators on the selected channel (recomputed at most 4x/sec)
        function getBandPercentages(ch) {
            if (sampleCountTotal < 32) {
                return [28, 46, 26]; // [Theta%, Alpha%, Beta%]
            }
            if (ch == lastBandCh) {
                return cachedBands;
            }
            lastBandCh = ch;
            var buf = getChannelBuffer(ch);
            var eSlow = 1.0;  // Theta (~4-7 Hz)
            var eMid  = 1.0;  // Alpha (~10 Hz)
            var eFast = 1.0;  // Beta  (~20+ Hz)

            // Sample 16 points (stride 2) across recent 32 samples for fast estimation
            for (var i = 0; i < 32; i += 2) {
                var idx0 = (writeIndex - 1 - i + BUFFER_SIZE) % BUFFER_SIZE;
                var idx3 = (writeIndex - 4 - i + BUFFER_SIZE) % BUFFER_SIZE;
                var idx12 = (writeIndex - 13 - i + BUFFER_SIZE) % BUFFER_SIZE;

                var v0 = buf[idx0];
                var v3 = buf[idx3];
                var v12 = buf[idx12];

                var dFast = v0 - v3;
                eFast += (dFast * dFast) * 0.32;

                var dAlpha = v0 - v12;
                eMid += (dAlpha * dAlpha) * 0.28;

                var dSlow = (v0 + v3) * 0.5;
                eSlow += (dSlow * dSlow) * 0.45;
            }

            var total = eSlow + eMid + eFast;
            if (total <= 0.0) {
                cachedBands = [30, 45, 25];
                return cachedBands;
            }
            var thetaPct = ((eSlow * 100.0) / total).toNumber();
            var alphaPct = ((eMid  * 100.0) / total).toNumber();
            var betaPct  = 100 - thetaPct - alphaPct;
            if (betaPct < 5) { betaPct = 5; }
            cachedBands = [thetaPct, alphaPct, betaPct];
            return cachedBands;
        }

        function getMeasuredSps() { return measuredSps; }
        function getMeasuredPps() { return measuredPps; }
        function getPacketsReceived() { return packetsReceived; }
        function getSamplesReceived() { return samplesReceived; }
        function getDroppedSamples() { return droppedSamples; }

        function reset() {
            for (var ch = 0; ch < NUM_CHANNELS; ch++) {
                var buf = channelBuffers[ch];
                for (var i = 0; i < BUFFER_SIZE; i++) {
                    buf[i] = 0.0;
                }
                latestUv[ch] = 0.0;
                dcOffsetUv[ch] = 0.0;
                meanSqUv[ch] = 0.0;
                cachedRmsUv[ch] = 0.0;
                cachedSqi[ch] = 0;
            }
            writeIndex = 0;
            sampleCountTotal = 0;
            lastSeqCounter = null;
            packetsReceived = 0;
            samplesReceived = 0;
            droppedSamples = 0;
            measuredSps = 0;
            measuredPps = 0;
            samplesSinceLastCalc = 0;
            packetsSinceLastCalc = 0;
            lastRateCalcMs = System.getTimer();
            lastMetricsUpdateMs = 0;
            lastBandCh = -1;
        }
    }
}
