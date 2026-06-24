%{
  name: :mob_bluetooth,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "Bluetooth Classic (BR/EDR) — discovery, pairing, HFP + SPP profiles",
  nifs: [
    # lang: :zig routes this through -Dplugin_zig_nifs + addZigObject. :module
    # is the C/Erlang NIF name; the source's `mob_bluetooth_nif_nif_init` export
    # is the static init symbol the generated driver table references.
    %{module: :mob_bluetooth_nif, native_dir: "priv/native/jni", lang: :zig}
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
    plist_keys: %{
      NSBluetoothAlwaysUsageDescription:
        "Bluetooth access is required to discover and pair external devices."
    }
  }
}
