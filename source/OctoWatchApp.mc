using Toybox.Application;
using Toybox.BluetoothLowEnergy;
using Toybox.WatchUi;

// Main Application Entry Point
class OctoWatchApp extends Application.AppBase {

    private var _profileManager;
    private var _ringBuffer;
    private var _bleDelegate;
    private var _view;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
        _profileManager = new OctoWatch.OctoProfileManager();
        _ringBuffer = new OctoWatch.EegRingBuffer();
        _bleDelegate = new OctoWatch.OctoBleDelegate(_profileManager, _ringBuffer);

        BluetoothLowEnergy.setDelegate(_bleDelegate);
        _profileManager.registerProfiles();
    }

    function onStop(state) {
        try {
            BluetoothLowEnergy.setScanState(BluetoothLowEnergy.SCAN_STATE_OFF);
        } catch (e) {}
    }

    function getInitialView() {
        _view = new OctoWatch.OctoWatchView(_ringBuffer, _bleDelegate);
        var delegate = new OctoWatch.OctoWatchDelegate(_view);
        return [_view, delegate];
    }
}
