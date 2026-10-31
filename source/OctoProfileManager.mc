using Toybox.BluetoothLowEnergy;

module OctoWatch {

    // Octopus-16 BLE GATT Profile Manager
    // Matches PiEEG Octopus-16 ESP32-S3 firmware:
    //   Service UUID:  4fafc201-1fb5-459e-8fcc-c5c9c331914b
    //   Data (NOTIFY): beb5483e-36e1-4688-b7f5-ea07361b26a8
    //   Cmd  (WRITE):  c0de0001-36e1-4688-b7f5-ea07361b26a8
    class OctoProfileManager {

        public const OCTOPUS_SERVICE_UUID = BluetoothLowEnergy.stringToUuid("4fafc201-1fb5-459e-8fcc-c5c9c331914b");
        public const OCTOPUS_DATA_CHAR_UUID = BluetoothLowEnergy.stringToUuid("beb5483e-36e1-4688-b7f5-ea07361b26a8");
        public const OCTOPUS_CMD_CHAR_UUID  = BluetoothLowEnergy.stringToUuid("c0de0001-36e1-4688-b7f5-ea07361b26a8");

        private const _octopusProfileDef = {
            :uuid => OCTOPUS_SERVICE_UUID,
            :characteristics => [
                {
                    :uuid => OCTOPUS_DATA_CHAR_UUID,
                    :descriptors => [BluetoothLowEnergy.cccdUuid()]
                },
                {
                    :uuid => OCTOPUS_CMD_CHAR_UUID,
                    :descriptors => [BluetoothLowEnergy.cccdUuid()]
                }
            ]
        };

        function initialize() {
        }

        function registerProfiles() {
            try {
                BluetoothLowEnergy.registerProfile(_octopusProfileDef);
            } catch (e) {
                // Ignore if already registered
            }
        }
    }
}
