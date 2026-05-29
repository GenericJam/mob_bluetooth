%{
  name: :mob_bluetooth,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "Bluetooth Classic (BR/EDR) — discovery, pairing, HFP/HID/SPP profiles",
  android: %{
    permissions: [
      "android.permission.BLUETOOTH_CONNECT",
      "android.permission.BLUETOOTH_SCAN"
    ]
  },
  ios: %{
    plist_keys: %{
      NSBluetoothAlwaysUsageDescription:
        "Bluetooth access is required to discover and pair external devices."
    }
  }
}
