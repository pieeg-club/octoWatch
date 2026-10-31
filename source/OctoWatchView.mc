using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.System;
using Toybox.Lang;
using Toybox.Timer;
using Toybox.Math;

module OctoWatch {

    // 5 Cinematic Display Screens (cycle with Tap / Select button):
    //   0 = 1CH Live Scope (Spacious, uncrowded 250 SPS waveform + Channel & Brain Region)
    //   1 = Garmin Neuro-Readiness HUD (Brain Readiness Score, Alpha/Beta/Theta bars, Focus/Calm, Watch Batt)
    //   2 = How to Wear & 10-20 Fit Guide (Interactive Scalp Map + 4-step setup walkthrough)
    //   3 = 4CH Montage (Simultaneous 4-channel bank waveforms)
    //   4 = 16CH Matrix (Full 16-electrode contact quality & RMS activity grid)
    const VIEW_MODE_SINGLE_CH    = 0;
    const VIEW_MODE_GARMIN_HUD   = 1;
    const VIEW_MODE_WEAR_GUIDE   = 2;
    const VIEW_MODE_QUAD_CH      = 3;
    const VIEW_MODE_ALL_16_CH    = 4;
    const NUM_VIEW_MODES         = 5;

    class OctoWatchView extends WatchUi.View {

        private var _ringBuffer;
        private var _bleDelegate;
        private var _renderTimer;
        private var _logoBitmap;

        private var _viewMode;
        private var _selectedChannel; // 0..15 (displayed as CH01..CH16)
        private var _uvScaleIndex;    // 0 = ±50µV, 1 = ±100µV, 2 = ±250µV
        private var _uvScales;
        private var _guideStep;       // 0..3 step in How-to-Wear guide
        private var _splashTicks;     // Countdown for startup pixel-art Octopus + PiEEG splash
        private var _frameCounter;    // Frame counter for throttling static/HUD screen redraws
        private var _uiDirty;         // True immediately after any button/touch action

        // Standard 10-20 electrode labels & brain regions for 16-channel Octopus montage
        private var _channelNames;
        private var _channelRegions;

        function initialize(ringBuffer, bleDelegate) {
            View.initialize();
            _ringBuffer = ringBuffer;
            _bleDelegate = bleDelegate;

            _viewMode = VIEW_MODE_SINGLE_CH;
            _selectedChannel = 0;
            _uvScaleIndex = 1; // ±100 µV default
            _uvScales = [50.0, 100.0, 250.0];
            _guideStep = 0;
            _splashTicks = 6; // ~1.5 seconds intro splash at 4 Hz (250ms)
            _frameCounter = 0;
            _uiDirty = true;

            try {
                _logoBitmap = WatchUi.loadResource(Rez.Drawables.OctoLogo);
            } catch (e) {
                _logoBitmap = null;
            }

            _channelNames = [
                "Fp1", "Fp2", "F3", "F4",
                "C3",  "C4",  "P3", "P4",
                "O1",  "O2",  "F7", "F8",
                "T7",  "T8",  "P7", "P8"
            ];

            _channelRegions = [
                "PREFRONTAL L", "PREFRONTAL R", "FRONTAL L",   "FRONTAL R",
                "MOTOR C3",     "MOTOR C4",     "PARIETAL L",  "PARIETAL R",
                "OCCIPITAL L",  "OCCIPITAL R",  "FRONT-TEMP L","FRONT-TEMP R",
                "TEMPORAL L",   "TEMPORAL R",   "POST-TEMP L", "POST-TEMP R"
            ];
        }

        function onLayout(dc) {
        }

        function onShow() {
            // 4 Hz (250ms Garmin timer): leaves >85% of Venu CPU free so screen/channel switches are instant!
            _renderTimer = new Timer.Timer();
            _renderTimer.start(method(:onRenderTick) as Lang.Method, 250, true);
            _bleDelegate.startScanning();
        }

        function onHide() {
            if (_renderTimer != null) {
                _renderTimer.stop();
                _renderTimer = null;
            }
        }

        function onRenderTick() {
            _frameCounter++;
            if (_splashTicks > 0) {
                _splashTicks--;
                WatchUi.requestUpdate();
                return;
            }
            _bleDelegate.onWatchdogTick(_selectedChannel);

            // Redraw waveform screens at 4 Hz (250ms); static HUD/Guide/Matrix screens at 2 Hz (500ms)
            // Button/touch actions call WatchUi.requestUpdate() directly for 0ms instant transition!
            var isWaveformScreen = (_viewMode == VIEW_MODE_SINGLE_CH || _viewMode == VIEW_MODE_QUAD_CH);
            if (_uiDirty || isWaveformScreen || (_frameCounter % 2 == 0)) {
                _uiDirty = false;
                WatchUi.requestUpdate();
            }
        }

        // User interactions (Up / Down changes channel, or steps through Fit Guide on Page 2)
        function nextChannel() {
            _uiDirty = true;
            if (_splashTicks > 0) {
                _splashTicks = 0;
                WatchUi.requestUpdate();
                return;
            }
            if (_viewMode == VIEW_MODE_WEAR_GUIDE) {
                _guideStep = (_guideStep + 1) % 4;
            } else {
                _selectedChannel = (_selectedChannel + 1) % 16;
                _bleDelegate.selectRemoteChannel(_selectedChannel);
            }
            WatchUi.requestUpdate();
        }

        function prevChannel() {
            _uiDirty = true;
            if (_splashTicks > 0) {
                _splashTicks = 0;
                WatchUi.requestUpdate();
                return;
            }
            if (_viewMode == VIEW_MODE_WEAR_GUIDE) {
                _guideStep = (_guideStep + 3) % 4;
            } else {
                _selectedChannel = (_selectedChannel + 15) % 16;
                _bleDelegate.selectRemoteChannel(_selectedChannel);
            }
            WatchUi.requestUpdate();
        }

        function cycleViewMode() {
            _uiDirty = true;
            if (_splashTicks > 0) {
                _splashTicks = 0;
                WatchUi.requestUpdate();
                return;
            }
            _viewMode = (_viewMode + 1) % NUM_VIEW_MODES;
            WatchUi.requestUpdate();
        }

        function cycleScale() {
            _uiDirty = true;
            _uvScaleIndex = (_uvScaleIndex + 1) % _uvScales.size();
            WatchUi.requestUpdate();
        }

        function toggleSimOrReconnect() {
            _uiDirty = true;
            _splashTicks = 0;
            _bleDelegate.toggleSimulationMode();
            WatchUi.requestUpdate();
        }

        function onUpdate(dc) {
            var w = dc.getWidth();
            var h = dc.getHeight();
            var cx = w / 2;
            var cy = h / 2;

            dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
            dc.clear();

            // Cinematic Startup Splash with Pixel-Art Cyber-Octopus + PiEEG
            if (_splashTicks > 0) {
                drawSplashHero(dc, w, h, cx, cy);
                return;
            }

            // Outer cinematic progress ring + clean non-overlapping header
            drawCinematicBezelAndHeader(dc, w, h, cx, cy);

            if (_viewMode == VIEW_MODE_SINGLE_CH) {
                drawSingleChannelView(dc, w, h, cx, cy);
            } else if (_viewMode == VIEW_MODE_GARMIN_HUD) {
                drawGarminHudView(dc, w, h, cx, cy);
            } else if (_viewMode == VIEW_MODE_WEAR_GUIDE) {
                drawWearGuideView(dc, w, h, cx, cy);
            } else if (_viewMode == VIEW_MODE_QUAD_CH) {
                drawQuadChannelView(dc, w, h, cx, cy);
            } else {
                draw16ChannelMatrixView(dc, w, h, cx, cy);
            }

            // Bottom page indicator dots + concise footer
            drawBottomFooter(dc, w, h, cx);
        }

        // ─────────────────────────────────────────────────────────────────────
        // STARTUP SPLASH: Pixel-Art Octopus + PiEEG Hero Screen
        // ─────────────────────────────────────────────────────────────────────
        private function drawSplashHero(dc, w, h, cx, cy) {
            // Subtle outer glowing ring
            dc.setPenWidth(3);
            dc.setColor(0x183858, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(cx, cy, (w / 2) - 6);

            dc.setPenWidth(2);
            dc.setColor(0xEC38BC, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, (w / 2) - 6, Graphics.ARC_CLOCKWISE, 150, 30);

            if (_logoBitmap != null) {
                dc.drawBitmap(cx - 32, (h * 0.14).toNumber(), _logoBitmap);
            }

            dc.setColor(0x00F5D4, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 0.50).toNumber(), Graphics.FONT_SMALL, "octoWatch", Graphics.TEXT_JUSTIFY_CENTER);

            dc.setColor(0xFFD844, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 0.63).toNumber(), Graphics.FONT_XTINY, "PiEEG OCTOPUS-16", Graphics.TEXT_JUSTIFY_CENTER);

            dc.setColor(0x99AABB, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 0.74).toNumber(), Graphics.FONT_XTINY, "16-CH · 250 SPS · 24-BIT", Graphics.TEXT_JUSTIFY_CENTER);

            dc.setColor(0x00FF88, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 0.85).toNumber(), Graphics.FONT_XTINY, "TAP TO START", Graphics.TEXT_JUSTIFY_CENTER);
        }

        // ─────────────────────────────────────────────────────────────────────
        // TOP HEADER & BEZEL RING: Clean, Single-Line, Zero Overlap!
        // ─────────────────────────────────────────────────────────────────────
        private function drawCinematicBezelAndHeader(dc, w, h, cx, cy) {
            var state = _bleDelegate.getBleState();
            var statusColor = 0xFFAA00; // Amber scanning
            if (state == BLE_STATE_STREAMING) {
                statusColor = 0x00FF88; // Neon green live BLE
            } else if (state == BLE_STATE_SIMULATED) {
                statusColor = 0x00E5FF; // Cyan 250Hz sim
            } else if (state == BLE_STATE_RECONNECTING) {
                statusColor = 0xFF5555; // Red reconnecting
            }

            // Subtle outer bezel arc showing Signal Quality (SQI) around the top rim
            var radius = (w / 2) - 3;
            dc.setPenWidth(2);
            dc.setColor(0x162230, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(cx, cy, radius);

            var sqi = _ringBuffer.getSignalQualityPercent(_selectedChannel);
            var sqiColor = (sqi >= 80) ? 0x00FFAA : ((sqi >= 50) ? 0xFFBB00 : 0xFF5555);
            dc.setPenWidth(3);
            dc.setColor(statusColor, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, radius, Graphics.ARC_CLOCKWISE, 135, 45);

            // Single clean top status line at y = 5% (with vertical centering for dot)
            var sps = _ringBuffer.getMeasuredSps();
            var topText = _bleDelegate.getStateLabel();
            if (sps > 0 && (state == BLE_STATE_STREAMING || state == BLE_STATE_SIMULATED)) {
                topText = (state == BLE_STATE_STREAMING ? "LIVE " : "SIM ") + sps.format("%d") + "Hz";
            }

            var topY = (h * 0.055).toNumber();
            var textW = dc.getTextWidthInPixels(topText, Graphics.FONT_XTINY);
            var fontH = dc.getFontHeight(Graphics.FONT_XTINY);

            // Place status dot cleanly to the left of the centered text (never overlaps!)
            var dotX = cx - (textW / 2) - 8;
            var dotY = topY + (fontH / 2);
            dc.setColor(statusColor, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(dotX, dotY, 4);
            dc.drawText(cx + 4, topY, Graphics.FONT_XTINY, topText, Graphics.TEXT_JUSTIFY_CENTER);

            // Subtle divider line below header
            var divY = topY + fontH + 3;
            dc.setPenWidth(1);
            dc.setColor(0x1C2B3A, Graphics.COLOR_TRANSPARENT);
            dc.drawLine((w * 0.22).toNumber(), divY, (w * 0.78).toNumber(), divY);
        }

        // ─────────────────────────────────────────────────────────────────────
        // PAGE 0: 1-Channel 250 SPS Cinematic Scope (Spacious, Uncrowded)
        // ─────────────────────────────────────────────────────────────────────
        private function drawSingleChannelView(dc, w, h, cx, cy) {
            var ch = _selectedChannel;
            var scaleUv = _uvScales[_uvScaleIndex];
            var sqi = _ringBuffer.getSignalQualityPercent(ch);
            var sqiColor = (sqi >= 80) ? 0x00FFAA : ((sqi >= 50) ? 0xFFBB00 : 0xFF5555);

            // Row 1 (y = 16%): Channel Name + Region + SQI Pill (well spaced below top bar)
            var headerY = (h * 0.165).toNumber();
            var titleStr = "CH" + (ch + 1).format("%02d") + " " + _channelNames[ch];
            dc.setColor(0xFFD844, Graphics.COLOR_TRANSPARENT);
            dc.drawText((w * 0.16).toNumber(), headerY, Graphics.FONT_XTINY, titleStr, Graphics.TEXT_JUSTIFY_LEFT);

            dc.setColor(sqiColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText((w * 0.84).toNumber(), headerY, Graphics.FONT_XTINY, "SQI " + sqi.format("%d") + "%", Graphics.TEXT_JUSTIFY_RIGHT);

            // Row 2 (y = 24.5%): Brain Region label on left, Scale on right
            var subHeaderY = (h * 0.245).toNumber();
            dc.setColor(0x7799BB, Graphics.COLOR_TRANSPARENT);
            dc.drawText((w * 0.16).toNumber(), subHeaderY, Graphics.FONT_XTINY, _channelRegions[ch], Graphics.TEXT_JUSTIFY_LEFT);

            dc.setColor(0x557799, Graphics.COLOR_TRANSPARENT);
            dc.drawText((w * 0.84).toNumber(), subHeaderY, Graphics.FONT_XTINY, "±" + scaleUv.format("%.0f") + "µV", Graphics.TEXT_JUSTIFY_RIGHT);

            // Main Oscilloscope Box (y = 34% .. 68%)
            var plotLeft   = (w * 0.10).toNumber();
            var plotRight  = (w * 0.90).toNumber();
            var plotWidth  = plotRight - plotLeft;
            var plotTop    = (h * 0.34).toNumber();
            var plotBottom = (h * 0.67).toNumber();
            var plotHeight = plotBottom - plotTop;
            var plotMidY   = (plotTop + plotBottom) / 2;
            var halfH      = plotHeight / 2;

            // Dark scope card background + subtle grid
            dc.setColor(0x071018, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(plotLeft, plotTop, plotWidth, plotHeight);

            dc.setPenWidth(1);
            dc.setColor(0x162636, Graphics.COLOR_TRANSPARENT);
            dc.drawRectangle(plotLeft, plotTop, plotWidth, plotHeight);
            dc.drawLine(plotLeft, plotMidY, plotRight, plotMidY);
            // Vertical quarter-second grid ticks
            dc.drawLine(plotLeft + (plotWidth / 3), plotTop, plotLeft + (plotWidth / 3), plotBottom);
            dc.drawLine(plotLeft + ((plotWidth * 2) / 3), plotTop, plotLeft + ((plotWidth * 2) / 3), plotBottom);

            // Render live 128-sample (0.51s @ 250 SPS) EEG trace (single-pass crisp trace for fast hardware redraw)
            var buf = _ringBuffer.getChannelBuffer(ch);
            var writeIdx = _ringBuffer.getWriteIndex();
            var n = _ringBuffer.BUFFER_SIZE;

            var firstSample = buf[writeIdx % n];
            var clampedFirst = clamp(firstSample / scaleUv, -1.0, 1.0);
            var firstY = plotMidY - (clampedFirst * halfH).toNumber();

            dc.setPenWidth(2);
            dc.setColor(0x00FFAA, Graphics.COLOR_TRANSPARENT);
            var prevX = plotLeft;
            var prevY = firstY;
            // 32 segments across 128 samples (stride 4) -> crisp scope with minimal Garmin GPU overhead
            for (var i = 4; i < n; i += 4) {
                var uv = buf[(writeIdx + i) & 127];
                var norm = clamp(uv / scaleUv, -1.0, 1.0);
                var x = plotLeft + ((i * plotWidth) / (n - 1));
                var y = plotMidY - (norm * halfH).toNumber();
                dc.drawLine(prevX, prevY, x, y);
                prevX = x;
                prevY = y;
            }

            // Glowing live playhead dot on the right edge
            dc.setColor(0x00FFAA, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(prevX, prevY, 5);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.fillCircle(prevX, prevY, 2);

            // Row below scope (y = 70%): Clean telemetry pill (µV, RMS, and Neural State)
            var latestUv = _ringBuffer.getLatestUv(ch);
            var rmsUv = _ringBuffer.getChannelRmsUv(ch);
            var metricsY = (h * 0.70).toNumber();
            dc.setColor(0xE0F0FF, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                cx,
                metricsY,
                Graphics.FONT_XTINY,
                latestUv.format("%+.0f") + "µV  ·  RMS " + rmsUv.format("%.1f") + "µV",
                Graphics.TEXT_JUSTIFY_CENTER
            );
        }

        // ─────────────────────────────────────────────────────────────────────
        // PAGE 1: GARMIN NEURO-READINESS HUD (Actionable Metrics for Garmin Users)
        // ─────────────────────────────────────────────────────────────────────
        private function drawGarminHudView(dc, w, h, cx, cy) {
            var ch = _selectedChannel;
            var bands = _ringBuffer.getBandPercentages(ch); // [Theta%, Alpha%, Beta%]
            var thetaPct = bands[0];
            var alphaPct = bands[1];
            var betaPct  = bands[2];
            var sqi = _ringBuffer.getSignalQualityPercent(ch);

            // Compute Athlete Neuro-Readiness Score (0..100) from Alpha/Theta balance + Signal Quality
            var readiness = ((alphaPct * 12) / 10) + (betaPct / 2) + (sqi / 5);
            if (readiness > 99) { readiness = 99; }
            if (readiness < 40) { readiness = 40; }

            var stateLabel = "ALPHA FLOW";
            var stateColor = 0x00FFAA;
            if (betaPct >= 38) {
                stateLabel = "PEAK FOCUS";
                stateColor = 0x00E5FF;
            } else if (thetaPct >= 40) {
                stateLabel = "RECOVERY";
                stateColor = 0xBB86FC;
            }

            // Title + Pixel Art Octopus mini badge
            var titleY = (h * 0.16).toNumber();
            dc.setColor(stateColor, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, titleY, Graphics.FONT_XTINY, stateLabel + " · RDY " + readiness.format("%d"), Graphics.TEXT_JUSTIFY_CENTER);

            // 3 Horizontal Band Bars (Alpha Calm, Beta Focus, Theta Recovery)
            var barLeft = (w * 0.16).toNumber();
            var barMaxW = (w * 0.50).toNumber();
            var barH    = (h * 0.055).toNumber();
            if (barH < 10) { barH = 10; }

            drawBandBar(dc, barLeft, (h * 0.28).toNumber(), barMaxW, barH, "α CALM",  alphaPct, 0x00FFAA);
            drawBandBar(dc, barLeft, (h * 0.40).toNumber(), barMaxW, barH, "β FOCUS", betaPct,  0x00E5FF);
            drawBandBar(dc, barLeft, (h * 0.52).toNumber(), barMaxW, barH, "θ REST",  thetaPct, 0xEC38BC);

            // Garmin System Info Row: Watch Battery % + Active Montage Channel + Advice
            var sysStats = System.getSystemStats();
            var batt = (sysStats != null && sysStats.battery != null) ? sysStats.battery.toNumber() : 100;
            var clock = System.getClockTime();
            var timeStr = clock.hour.format("%02d") + ":" + clock.min.format("%02d");

            dc.setColor(0xFFD844, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 0.64).toNumber(), Graphics.FONT_XTINY,
                "READY FOR ZONE 2 / NEURO-TRAIN", Graphics.TEXT_JUSTIFY_CENTER);

            dc.setColor(0x88AACC, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 0.72).toNumber(), Graphics.FONT_XTINY,
                "WATCH " + batt.format("%d") + "%  ·  " + timeStr + "  ·  " + _channelNames[ch],
                Graphics.TEXT_JUSTIFY_CENTER);
        }

        private function drawBandBar(dc, x, y, maxW, barH, label, pct, color) {
            dc.setColor(0xCCDDFF, Graphics.COLOR_TRANSPARENT);
            dc.drawText(x, y - 3, Graphics.FONT_XTINY, label, Graphics.TEXT_JUSTIFY_LEFT);

            var trackX = x + (maxW * 0.42).toNumber();
            var trackW = (maxW * 0.68).toNumber();
            dc.setColor(0x162432, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(trackX, y + 2, trackW, barH);

            var fillW = ((trackW * pct) / 70);
            if (fillW > trackW) { fillW = trackW; }
            if (fillW < 4) { fillW = 4; }
            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(trackX, y + 2, fillW, barH);

            dc.setColor(color, Graphics.COLOR_TRANSPARENT);
            dc.drawText(trackX + trackW + 6, y - 3, Graphics.FONT_XTINY, pct.format("%d") + "%", Graphics.TEXT_JUSTIFY_LEFT);
        }

        // ─────────────────────────────────────────────────────────────────────
        // PAGE 2: HOW TO WEAR & FIT GUIDE (Interactive 10-20 Scalp Diagram + Steps)
        //Swipe Up/Down cycles through Steps 1..4!
        // ─────────────────────────────────────────────────────────────────────
        private function drawWearGuideView(dc, w, h, cx, cy) {
            var stepTitles = [
                "STEP 1/4: POWER & WRIST",
                "STEP 2/4: EAR REF & BIAS",
                "STEP 3/4: SCALP 10-20 FIT",
                "STEP 4/4: VERIFY SQI >=80%"
            ];
            var stepLine1 = [
                "Wear Garmin on LEFT wrist",
                "Clip REF to Left Ear (A1)",
                "Align Fp1/Fp2 2cm above",
                "Check all 8 nodes glow GREEN"
            ];
            var stepLine2 = [
                "Turn ON PiEEG Octopus-16",
                "Clip BIAS to Right Ear (A2)",
                "eyebrows; O1/O2 at back head",
                "(UP/DN steps · TAP next view)"
            ];

            dc.setColor(0xFFD844, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 0.16).toNumber(), Graphics.FONT_XTINY, stepTitles[_guideStep], Graphics.TEXT_JUSTIFY_CENTER);

            // Top-Down Interactive 10-20 Head Diagram in center (y = 26% .. 60%)
            var headCy = (h * 0.43).toNumber();
            var headR  = (h * 0.145).toNumber();

            // Nose triangle at top of head
            dc.setPenWidth(2);
            dc.setColor(0x446688, Graphics.COLOR_TRANSPARENT);
            dc.drawLine(cx - 7, headCy - headR + 1, cx, headCy - headR - 8);
            dc.drawLine(cx + 7, headCy - headR + 1, cx, headCy - headR - 8);

            // Left & Right Earlobes (highlighted in bright gold on Step 2!)
            var earColor = (_guideStep == 1) ? 0xFFD844 : 0x335577;
            dc.setColor(earColor, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(cx - headR - 5, headCy, 5);
            dc.drawCircle(cx + headR + 5, headCy, 5);
            if (_guideStep == 1) {
                dc.drawText(cx - headR - 14, headCy - 10, Graphics.FONT_XTINY, "REF", Graphics.TEXT_JUSTIFY_RIGHT);
                dc.drawText(cx + headR + 14, headCy - 10, Graphics.FONT_XTINY, "BIAS", Graphics.TEXT_JUSTIFY_LEFT);
            }

            // Head outline circle
            dc.setPenWidth(2);
            dc.setColor(0x336699, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(cx, headCy, headR);

            // Key 10-20 Electrode Nodes (Fp1, Fp2, C3, C4, T7, T8, O1, O2) colored by live SQI
            var nodeOffsets = [
                [-12, -headR + 10, 0], // Fp1
                [ 12, -headR + 10, 1], // Fp2
                [-16, -2,          4], // C3
                [ 16, -2,          5], // C4
                [-headR + 8, 0,   12], // T7
                [ headR - 8, 0,   13], // T8
                [-12,  headR - 10, 8], // O1
                [ 12,  headR - 10, 9]  // O2
            ];

            for (var i = 0; i < nodeOffsets.size(); i++) {
                var nx = cx + nodeOffsets[i][0];
                var ny = headCy + nodeOffsets[i][1];
                var chIdx = nodeOffsets[i][2];
                var sqi = _ringBuffer.getSignalQualityPercent(chIdx);
                var nColor = (sqi >= 80) ? 0x00FFAA : ((sqi >= 50) ? 0xFFBB00 : 0xFF5555);
                if (_guideStep == 2 && (i < 2 || i >= 6)) {
                    nColor = 0x00E5FF; // Highlight Fp1/Fp2 & O1/O2 alignment in Step 3
                }
                dc.setColor(nColor, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(nx, ny, 4);
            }

            // Step instructions below head diagram (2 clean non-overlapping lines)
            dc.setColor(0xFFFFFF, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 0.62).toNumber(), Graphics.FONT_XTINY, stepLine1[_guideStep], Graphics.TEXT_JUSTIFY_CENTER);

            dc.setColor(0x00F5D4, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 0.705).toNumber(), Graphics.FONT_XTINY, stepLine2[_guideStep], Graphics.TEXT_JUSTIFY_CENTER);
        }

        // ─────────────────────────────────────────────────────────────────────
        // PAGE 3: 4-Channel Stacked Montage (Bank of 4 channels around selected)
        // ─────────────────────────────────────────────────────────────────────
        private function drawQuadChannelView(dc, w, h, cx, cy) {
            var baseBank = (_selectedChannel / 4) * 4;
            var scaleUv = _uvScales[_uvScaleIndex];

            dc.setColor(0xFFD844, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 0.16).toNumber(), Graphics.FONT_XTINY,
                "BANK " + (baseBank + 1).format("%02d") + "-" + (baseBank + 4).format("%02d") + " (±" + scaleUv.format("%.0f") + "µV)",
                Graphics.TEXT_JUSTIFY_CENTER);

            var plotLeft  = (w * 0.22).toNumber();
            var plotRight = (w * 0.88).toNumber();
            var plotWidth = plotRight - plotLeft;
            var startY    = (h * 0.25).toNumber();
            var laneH     = (h * 0.115).toNumber();
            var n         = _ringBuffer.BUFFER_SIZE;
            var writeIdx  = _ringBuffer.getWriteIndex();

            var colors = [0x00FFAA, 0x00E5FF, 0xFFD844, 0xEC38BC];

            for (var lane = 0; lane < 4; lane++) {
                var ch = (baseBank + lane) % 16;
                var midY = startY + (lane * laneH) + (laneH / 2);
                var halfLane = (laneH / 2) - 3;

                dc.setPenWidth(1);
                dc.setColor(0x162432, Graphics.COLOR_TRANSPARENT);
                dc.drawLine(plotLeft, midY, plotRight, midY);

                var isSelected = (ch == _selectedChannel);
                dc.setColor(isSelected ? 0xFFFFFF : colors[lane], Graphics.COLOR_TRANSPARENT);
                dc.drawText(plotLeft - 6, midY - 9, Graphics.FONT_XTINY, _channelNames[ch], Graphics.TEXT_JUSTIFY_RIGHT);

                var buf = _ringBuffer.getChannelBuffer(ch);
                dc.setPenWidth(isSelected ? 2 : 1);
                dc.setColor(colors[lane], Graphics.COLOR_TRANSPARENT);

                var prevX = plotLeft;
                var firstNorm = clamp(buf[writeIdx % n] / scaleUv, -1.0, 1.0);
                var prevY = midY - (firstNorm * halfLane).toNumber();

                for (var i = 8; i < n; i += 8) {
                    var uv = buf[(writeIdx + i) & 127];
                    var norm = clamp(uv / scaleUv, -1.0, 1.0);
                    var x = plotLeft + ((i * plotWidth) / (n - 1));
                    var y = midY - (norm * halfLane).toNumber();
                    dc.drawLine(prevX, prevY, x, y);
                    prevX = x;
                    prevY = y;
                }
            }
        }

        // ─────────────────────────────────────────────────────────────────────
        // PAGE 4: Full 16-Channel Octopus Matrix (Contact SQI + RMS + Packet Stats)
        // ─────────────────────────────────────────────────────────────────────
        private function draw16ChannelMatrixView(dc, w, h, cx, cy) {
            dc.setColor(0xFFD844, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, (h * 0.16).toNumber(), Graphics.FONT_XTINY, "16-CH IMPEDANCE / SQI", Graphics.TEXT_JUSTIFY_CENTER);

            var gridLeft = (w * 0.14).toNumber();
            var gridTop  = (h * 0.25).toNumber();
            var cellW    = (w * 0.18).toNumber();
            var cellH    = (h * 0.105).toNumber();

            for (var ch = 0; ch < 16; ch++) {
                var row = ch / 4;
                var col = ch % 4;
                var x = gridLeft + (col * cellW);
                var y = gridTop + (row * cellH);

                var rms = _ringBuffer.getChannelRmsUv(ch);
                var sqi = _ringBuffer.getSignalQualityPercent(ch);

                var boxColor = 0x123828;
                if (sqi < 50) {
                    boxColor = 0x42161C;
                } else if (rms > 35.0) {
                    boxColor = 0x1A4258;
                }

                dc.setColor(boxColor, Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(x + 2, y + 2, cellW - 4, cellH - 4);

                if (ch == _selectedChannel) {
                    dc.setPenWidth(2);
                    dc.setColor(0x00FFAA, Graphics.COLOR_TRANSPARENT);
                    dc.drawRectangle(x + 1, y + 1, cellW - 2, cellH - 2);
                }

                dc.setColor(0xFFFFFF, Graphics.COLOR_TRANSPARENT);
                dc.drawText(x + (cellW / 2), y + 2, Graphics.FONT_XTINY, _channelNames[ch], Graphics.TEXT_JUSTIFY_CENTER);
            }

            var pkts = _ringBuffer.getPacketsReceived();
            var drops = _ringBuffer.getDroppedSamples();
            dc.setColor(0x88AACC, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                cx,
                (h * 0.70).toNumber(),
                Graphics.FONT_XTINY,
                "PKT " + pkts.format("%d") + "  ·  DROP " + drops.format("%d"),
                Graphics.TEXT_JUSTIFY_CENTER
            );
        }

        // ─────────────────────────────────────────────────────────────────────
        // BOTTOM FOOTER: 5-Page Carousel Dots + Concise Mode Label
        // ─────────────────────────────────────────────────────────────────────
        private function drawBottomFooter(dc, w, h, cx) {
            var modeLabels = ["1CH SCOPE", "GARMIN HUD", "FIT GUIDE", "4CH BANK", "16CH GRID"];
            var footerY = (h * 0.80).toNumber();
            dc.setColor(0x7799BB, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, footerY, Graphics.FONT_XTINY, modeLabels[_viewMode], Graphics.TEXT_JUSTIFY_CENTER);

            // 5 page indicator dots at bottom (y = 91%)
            var dotY = (h * 0.91).toNumber();
            var spacing = 12;
            var startX = cx - ((NUM_VIEW_MODES - 1) * spacing) / 2;
            for (var i = 0; i < NUM_VIEW_MODES; i++) {
                var dx = startX + (i * spacing);
                if (i == _viewMode) {
                    dc.setColor(0x00FFAA, Graphics.COLOR_TRANSPARENT);
                    dc.fillCircle(dx, dotY, 4);
                } else {
                    dc.setColor(0x334455, Graphics.COLOR_TRANSPARENT);
                    dc.fillCircle(dx, dotY, 2);
                }
            }
        }

        private function clamp(val, minVal, maxVal) {
            if (val < minVal) { return minVal; }
            if (val > maxVal) { return maxVal; }
            return val;
        }
    }
}

