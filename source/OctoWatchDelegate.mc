using Toybox.WatchUi;

module OctoWatch {

    // Input Delegate for octoWatch:
    // - Tap / Select button: Cycle View Mode (1-Channel 250Hz Scope -> 4-Channel Montage -> 16-Channel Matrix)
    // - Swipe Up / Next Page: Next EEG Channel (CH01 .. CH16)
    // - Swipe Down / Prev Page: Previous EEG Channel (CH16 .. CH01)
    // - Long Press / Menu: Toggle between Live BLE Scan and 250 SPS Simulator / Force Reconnect
    class OctoWatchDelegate extends WatchUi.BehaviorDelegate {

        private var _view;

        function initialize(view) {
            BehaviorDelegate.initialize();
            _view = view;
        }

        function onSelect() {
            if (_view != null) {
                _view.cycleViewMode();
            }
            return true;
        }

        function onNextPage() {
            if (_view != null) {
                _view.nextChannel();
            }
            return true;
        }

        function onPreviousPage() {
            if (_view != null) {
                _view.prevChannel();
            }
            return true;
        }

        function onMenu() {
            if (_view != null) {
                _view.toggleSimOrReconnect();
            }
            return true;
        }

        function onBack() {
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
            return true;
        }
    }
}
