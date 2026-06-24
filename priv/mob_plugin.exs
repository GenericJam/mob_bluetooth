%{
  name: :mob_bluetooth,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "Bluetooth Classic (BR/EDR) — discovery, pairing, HFP + SPP profiles",
  nifs: [
    # Android: lang: :zig routes this through -Dplugin_zig_nifs + addZigObject.
    # :module is the C/Erlang NIF name; the source's `mob_bluetooth_nif_nif_init`
    # export is the static init symbol the generated driver table references.
    # platform: :android so it isn't pulled into the iOS build.
    %{module: :mob_bluetooth_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android},
    # iOS: the same NIF module name, but the ObjC CoreBluetooth implementation
    # (ble_* — a BLE surface; iOS has no classic-BT API). platform: :ios so the
    # Android build skips it. The two share the Erlang stub module
    # (src/mob_bluetooth_nif.erl); each platform's NIF provides only its own
    # functions and the Elixir layer gates calls per platform.
    %{module: :mob_bluetooth_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios}
  ],
  # Runtime permission capability — Android-only (BT Classic is unsupported on
  # iOS, so no ios handler). The Android bridge's MobPermissionProvider maps
  # :bluetooth_connect to the whole Nearby-devices group (SCAN/CONNECT/ADVERTISE);
  # core's request_permission consults it so Mob.Permissions.request(socket,
  # :bluetooth_connect) shows the runtime dialog and grants the group.
  permissions: [
    %{capability: :bluetooth_connect}
  ],
  android: %{
    permissions: [
      "android.permission.BLUETOOTH_CONNECT",
      "android.permission.BLUETOOTH_SCAN",
      # make_discoverable fires ACTION_REQUEST_DISCOVERABLE, which needs
      # BLUETOOTH_ADVERTISE on Android 12+.
      "android.permission.BLUETOOTH_ADVERTISE",
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
    # CoreBluetooth for the ble_* surface (CBCentralManager scan +
    # CBPeripheralManager advertise).
    frameworks: ["CoreBluetooth"],
    plist_keys: %{
      NSBluetoothAlwaysUsageDescription:
        "Bluetooth access is required to discover and advertise to nearby devices.",
      # Background BLE: bluetooth-central keeps scanning/connecting alive,
      # bluetooth-peripheral keeps advertising alive, when the app is
      # backgrounded. Array-MERGED into the host Info.plist by mob_dev >= 0.6.16
      # (so it composes with e.g. mob_background's `audio` entry). Background
      # scanning additionally requires a :service_uuids filter on ble_scan/2.
      # If Apple flags an unused mode at review, drop whichever of central/
      # peripheral this app does not use.
      UIBackgroundModes: ["bluetooth-central", "bluetooth-peripheral"]
    }
  }
}
