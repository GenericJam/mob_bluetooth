# Background BLE is OPT-IN per app. By default this plugin declares NO
# UIBackgroundModes (foreground-only), so apps that don't need background BLE
# don't ship an unused background-mode declaration (which Apple rejects at
# review). An app enables exactly the mode(s) it uses in its own config:
#
#     config :mob_bluetooth, ble_background_modes: [:central]                 # background scanning/connecting
#     config :mob_bluetooth, ble_background_modes: [:peripheral]              # background advertising
#     config :mob_bluetooth, ble_background_modes: [:central, :peripheral]    # both
#
# Each chosen mode adds the matching UIBackgroundModes entry to the host
# Info.plist (array-merged by mob_dev >= 0.6.16, so it composes with e.g.
# mob_background's `audio`). Background scanning additionally needs a
# `:service_uuids` filter on `ble_scan/2`.
#
# Read via MobDev.Plugin.host_config (apply/3 so this data file needn't
# compile-depend on mob_dev); guarded so the manifest still evaluates to a
# foreground-only config if mob_dev isn't loaded.
ble_background_modes =
  if Code.ensure_loaded?(MobDev.Plugin) do
    apply(MobDev.Plugin, :host_config, [:mob_bluetooth, :ble_background_modes, []])
  else
    []
  end
  |> List.wrap()
  |> Enum.flat_map(fn
    :central -> ["bluetooth-central"]
    :peripheral -> ["bluetooth-peripheral"]
    mode when is_binary(mode) -> [mode]
    _ -> []
  end)
  |> Enum.uniq()

ios_plist_keys = %{
  NSBluetoothAlwaysUsageDescription:
    "Bluetooth access is required to discover and advertise to nearby devices."
}

ios_plist_keys =
  if ble_background_modes == [],
    do: ios_plist_keys,
    else: Map.put(ios_plist_keys, :UIBackgroundModes, ble_background_modes)

%{
  name: :mob_bluetooth,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description: "Bluetooth Classic (BR/EDR) — discovery, pairing, HFP + SPP profiles",
  # Per-app config this plugin reads at build time (opt-in background BLE).
  host_config_keys: [:ble_background_modes],
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
    plist_keys: ios_plist_keys
  }
}
