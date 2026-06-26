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
  description:
    "Bluetooth Classic (BR/EDR) — discovery, pairing, HFP + SPP — plus BLE (Low Energy): central scan/advertise + GATT peripheral",
  # Per-app config this plugin reads at build time (opt-in background BLE).
  host_config_keys: [:ble_background_modes],
  nifs: [
    # Android: zig NIF under this module — Classic bt_* (incl. make_discoverable)
    # plus the LE GATT-peripheral ble_* (ble_start_advertising/notify) bridging
    # to the Kotlin MobBluetoothBridge. lang: :zig routes through
    # -Dplugin_zig_nifs + addZigObject; `mob_bluetooth_nif_nif_init` is the
    # static init symbol. platform: :android so the iOS build skips it.
    %{module: :mob_bluetooth_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android},
    # iOS: same NIF module name, ObjC over CoreBluetooth — the central
    # scan/advertise surface (ble_scan/ble_advertise) AND the GATT-peripheral
    # surface (ble_start_advertising/notify, CBPeripheralManager). iOS has no
    # classic-BT API, so only ble_* live here. platform: :ios so Android skips
    # it; the two share the erl stub and the Elixir layer gates per platform.
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
      # Android 12+ (API 31+) Nearby-devices runtime permissions.
      "android.permission.BLUETOOTH_CONNECT",
      "android.permission.BLUETOOTH_SCAN",
      # Android 12+ (API 31+): make_discoverable's ACTION_REQUEST_DISCOVERABLE
      # and LE peripheral advertising (MobBluetooth.Le) both need this.
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
    # CoreBluetooth for the ble_* surface: CBCentralManager scan +
    # CBPeripheralManager advertise (name) + GATT peripheral (service/notify).
    frameworks: ["CoreBluetooth"],
    plist_keys: ios_plist_keys
  }
}
