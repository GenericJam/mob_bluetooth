%{
  name: :mob_bluetooth,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description:
    "Bluetooth Classic (BR/EDR) — discovery, pairing, HFP + SPP — plus BLE (Low Energy) GATT peripheral",
  nifs: [
    # Android: zig NIF (Classic bt_* + LE ble_*) bridging to the Kotlin
    # MobBluetoothBridge. lang: :zig routes this through -Dplugin_zig_nifs +
    # addZigObject. :module is the C/Erlang NIF name; the source's
    # `mob_bluetooth_nif_nif_init` export is the static init symbol the
    # generated driver table references. platform: :android so the iOS build
    # skips it.
    %{module: :mob_bluetooth_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android},
    # iOS: ObjC NIF over CoreBluetooth (CBPeripheralManager) — the plugin's
    # first iOS native. Registers ONLY the LE ble_* functions under the same
    # erl module (Classic bt_* is MFi-gated and short-circuits to :unsupported
    # in Elixir before reaching the NIF). platform: :ios so Android skips it; a
    # same-module objc+zig pair is not a collision (see MOB_PLUGINS.md).
    %{module: :mob_bluetooth_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios}
  ],
  android: %{
    permissions: [
      # Android 12+ (API 31+) Nearby-devices runtime permissions.
      "android.permission.BLUETOOTH_CONNECT",
      "android.permission.BLUETOOTH_SCAN",
      # BLE peripheral advertising (MobBluetooth.Le) on Android 12+ (API 31+).
      "android.permission.BLUETOOTH_ADVERTISE",
      # Legacy install-time permissions for API <= 30 (Android 11 and below):
      # BLUETOOTH gates adapter state / GATT, BLUETOOTH_ADMIN gates
      # discovery + LE advertising. Auto-granted; ignored on API 31+. Without
      # these, adapter.isEnabled throws SecurityException on Android 11.
      "android.permission.BLUETOOTH",
      "android.permission.BLUETOOTH_ADMIN",
      # Discovery (startDiscovery) returns scan results only with location access.
      "android.permission.ACCESS_FINE_LOCATION"
    ],
    # Plain JNI-thunk C (Java_io_mob_bluetooth_*) compiled via
    # -Dplugin_jni_sources alongside beam_jni.c — holds the 25 nativeDeliverBt*
    # thunks that call the plugin NIF's mob_deliver_bt_* exports.
    jni_source: "priv/native/jni/mob_bluetooth_jni.c",
    # Plugin-owned Kotlin bridge class (own package, NOT the app's MobBridge).
    # mob_dev copies it into the app Kotlin sourceSet and generates
    # MobPluginBootstrap.registerAll() to call MobBluetoothBridge.register() at
    # startup, which caches the jclass + bt_* method ids natively.
    bridge_kt: "priv/native/android/MobBluetoothBridge.kt",
    bridge_class: "io.mob.bluetooth.MobBluetoothBridge"
  },
  ios: %{
    # CoreBluetooth (CBPeripheralManager) for the LE peripheral NIF. Linked at
    # the iOS static-link step.
    frameworks: ["CoreBluetooth"],
    plist_keys: %{
      NSBluetoothAlwaysUsageDescription:
        "Bluetooth access is required to discover and pair external devices, and to advertise as a Bluetooth LE peripheral."
    }
  }
}
