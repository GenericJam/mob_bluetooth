# Changelog

All notable changes to **mob_bluetooth** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Fixed

- **Android: HFP now emits `:bt_hfp, :connected` for newly-initiated
  connects and `:bt_hfp, :disconnected` for local + remote hang-ups**
  (MOB-63 + MOB-64). The pre-fix `bt_hfp_connect` only ever emitted
  `:connecting` for a fresh connection — the terminal `:connected`
  was documented but never fired, so consumers had no way to observe
  "your HFP is now live." `bt_disconnect` always emitted the
  SPP-shaped `:bt_spp, :disconnected` regardless of profile and never
  actually called the HFP `proxy.disconnect(device)` reflection method.

  A single lifetime-scoped `BroadcastReceiver` on
  `BluetoothHeadset.ACTION_CONNECTION_STATE_CHANGED` now drives both
  events. `bt_hfp_connect` registers it once + records the caller pid
  in `btHfpSessionPids`; `bt_disconnect` marks the session in
  `btHfpLocalDisconnects` before initiating the reflection call, so
  the receiver picks `reason = "local"` vs the "peer" default. SPP
  and HFP disconnects are now emitted independently (a session with
  both profiles active gets both events). The receiver filters to
  known sessions so system-initiated pairs (user pairs a headset via
  Settings) don't allocate phantom `btSessionMap` entries.

  Also folded from the pre-commit review: `connectedDevices()` calls
  are now `SecurityException`-guarded (`BLUETOOTH_CONNECT` on
  API 31+) so a revoked grant doesn't crash `bt_disconnect`, and a
  synchronous-false reflection result keeps the session pid mapped
  in case Android's HFP proxy still connects asynchronously.


### Fixed

- **Android: JNI exception no longer leaks onto the BEAM scheduler thread**
  (MOB-62). The zig NIF had zero `ExceptionCheck`/`ExceptionClear` calls,
  which meant a `SecurityException` raised by any Kotlin bridge method
  (BLUETOOTH_CONNECT/SCAN/ADVERTISE permission gap on Android 12+) or a
  `NoSuchMethodError` from an older/stripped bridge would linger on the
  JNIEnv. The next JNI call on the same BEAM scheduler thread was then
  undefined behaviour per the JNI spec.

  Fix mirrors mob core's `mob_ui_cache_class` pattern (see
  `mob/android/jni/mob_nif.zig`):
  - `nativeRegister` now caches every method through a new `cacheMethod`
    helper that clears any pending exception on a null return.
  - Every `CallStaticVoidMethod` site (13 direct + 1 in `callBridgePidStr`,
    which fans out to 5 more via `bt_pair` / `bt_unpair` / `bt_hfp_connect`
    / `bt_spp_connect` / `ble_start_advertising`) calls
    `jni.exceptionClear(jenv)` immediately after the call — the JNI spec
    guarantees the clear is a no-op if no exception is pending.

  Existing runtime NIFs already guarded on a missing method-id cache via
  `if (g_bt.<method> == null) return btUnsupported(env);`, so the `:unsupported`
  path continues to work. Return-type contracts are unchanged; no public
  API change. iOS path is untouched.

---

## [0.3.0] - 2026-06-26

### Added
- **BLE GATT peripheral role (`MobBluetooth.Le`).** Building on the 0.2.0 BLE
  central/advertise surface, this adds the *peripheral* role: run a GATT server,
  advertise a **service** with characteristics, push notifications to subscribed
  centrals, and receive writes — i.e. present the phone as a BLE accessory
  (sensor, BLE-MIDI peripheral) that a computer or another phone connects to and
  exchanges data with. API: `MobBluetooth.Le.start_advertising/2`,
  `stop_advertising/1`, `notify/3`; events tagged `:bt_le`
  (`:advertising_started`/`:advertising_failed`, `:central_connected`/
  `:central_disconnected`, `:subscribed`/`:unsubscribed`, `:write`).
- **Cross-platform** (unlike the iOS-only `ble_scan`/`ble_advertise` surface):
  `BluetoothGattServer` + `BluetoothLeAdvertiser` on Android, `CBPeripheralManager`
  GATT server on iOS — added to the existing `mob_bluetooth_nif`. Adds the legacy
  `BLUETOOTH` / `BLUETOOTH_ADMIN` permissions for API <= 30. Device-verified
  end-to-end on Android (Moto G power) and iOS (iPhone SE) driving a BLE-MIDI
  peripheral (mob_midi) that a Mac receives as live MIDI, both directions.

---

## [0.2.2] - 2026-06-24

### Changed
- **Background BLE is now opt-in per app** (was: both modes always declared in
  0.2.1). By default the plugin declares no `UIBackgroundModes`, so apps that
  don't need background BLE don't ship an unused background-mode declaration
  (which Apple rejects at review). An app enables exactly the mode(s) it uses:

      config :mob_bluetooth, ble_background_modes: [:central]              # background scanning/connecting
      config :mob_bluetooth, ble_background_modes: [:peripheral]           # background advertising
      config :mob_bluetooth, ble_background_modes: [:central, :peripheral] # both

  The manifest reads this at build time via `MobDev.Plugin.host_config` and
  contributes the matching `UIBackgroundModes` entries, array-merged into the
  host Info.plist by mob_dev >= 0.6.16. **Verified on a real iOS build**: with
  `[:central, :peripheral]` configured, the built app's Info.plist
  `UIBackgroundModes` = `[audio, bluetooth-central, bluetooth-peripheral]`
  (composing with a pre-existing entry). Requires **mob_dev >= 0.6.16**.

---

## [0.2.1] - 2026-06-24

### Added
- **Background BLE support.** The iOS BLE surface now actually works while the
  app is backgrounded, not just in the foreground:
  - The manifest declares `UIBackgroundModes` `bluetooth-central` +
    `bluetooth-peripheral`, merged into the host Info.plist by mob_dev >= 0.6.16
    (composes with any existing entry such as `audio`).
  - `ble_scan/2` takes a `:service_uuids` filter
    (`ble_scan(socket, service_uuids: ["180D"])`). iOS silently drops an
    unfiltered scan once backgrounded, so a filter is required for background
    scanning; omitting it keeps the previous foreground-only "scan for
    everything" behaviour. (`ble_scan(socket)` is unchanged.)

  See the "Background BLE" moduledoc section for the iOS throttling caveats
  (coalesced scans, no local name in background advertising). Requires
  **mob_dev >= 0.6.16** for the `UIBackgroundModes` array merge.

---

## [0.2.0] - 2026-06-24

### Added
- **iOS BLE surface (CoreBluetooth).** iOS has no public Bluetooth Classic API,
  so the existing `bt_*` surface (discovery, pairing, HFP, SPP) stays
  Android-only. This adds a separate, parallel **BLE** capability via
  CoreBluetooth, available on iOS:
  - `ble_scan/1` / `ble_stop_scan/1` — scan for nearby BLE peripherals
    (`CBCentralManager`), emitting `{:bt, :ble_scan_started}` and
    `{:bt, :ble_device, %{id, name, rssi}}` per advertisement.
  - `ble_advertise/2` / `ble_stop_advertise/1` — advertise this device as a BLE
    peripheral (`CBPeripheralManager`), emitting `{:bt, :ble_advertising}`.

  iOS-only (returns `{:error, :unsupported}` on Android, which has no BLE surface
  in this plugin yet), and needs a real radio, so it does nothing on the iOS
  Simulator. Ships an ObjC NIF (`priv/native/ios/mob_bluetooth_nif.m`) +
  the `CoreBluetooth` framework; events reuse the existing `:bt` device-event
  family. **Device-verified on a physical iPhone SE** (3rd gen): `ble_scan`
  returned real nearby peripherals with RSSI and `ble_advertise` started
  advertising.

---

## [0.1.3] - 2026-06-24

### Added
- **`:bluetooth_connect` runtime permission capability.** The Android bridge now
  implements `MobPermissionProvider`, mapping `:bluetooth_connect` to the whole
  Android 12+ "Nearby devices" group (`BLUETOOTH_CONNECT` / `BLUETOOTH_SCAN` /
  `BLUETOOTH_ADVERTISE`), and the manifest registers the capability. So
  `Mob.Permissions.request(socket, :bluetooth_connect)` now shows the runtime
  dialog and a single grant unlocks discovery, pairing, and `make_discoverable`
  together — previously the plugin declared the permissions but had no way to
  request the grant in-app (it returned `:denied` without a manual `adb grant`).
  Android-only (BT Classic is unsupported on iOS). Device-verified on a Moto G
  power 5G. (#2)

---

## [0.1.2] - 2026-06-24

### Added
- **`MobBluetooth.make_discoverable/2`** — request that the device become
  discoverable to nearby Bluetooth devices for `:duration` seconds (default 120)
  via `ACTION_REQUEST_DISCOVERABLE`, showing the system "make discoverable?"
  dialog. First call to exercise `BLUETOOTH_ADVERTISE` (now declared in the
  manifest). Fire-and-forget: the system dialog is the user-facing result; the
  accept/deny outcome is not captured (a follow-up needs `onActivityResult`
  plumbing). Failures (adapter off / permission not granted) arrive as
  `{:bt, :error, reason}`. An invalid `:duration` falls back to the default
  (pure, tested `discoverable_duration/1`). Device-verified on a Moto G power 5G
  (Android 15). (#1)

### Security
- Bumped `plug` 1.19.2 → 1.20.1 (dev/test-only transitive via `mob_dev`),
  clearing EEF-CVE-2026-54892 (quadratic-time nested-param decoding DoS). Does
  not ship in the package; lockfile-only.

---

## [0.1.1] - 2026-06-16

### Changed
- Signed release: the published package now carries a verified Ed25519
  signature (shared mob first-party key, regenerated in CI on every
  release). Generated apps trust it via `config :mob, :trusted_plugins`,
  so it clears the plugin signature gate without `acknowledge_unsafe_plugins`.

## [0.1.0] - 2026-06-12

Initial release. Bluetooth (discovery, SPP / HFP / HID) for Mob apps.

- Device discovery and connection management surfaced through `MobBluetooth`.
- Extracted from mob core in the 0.7.0 plugin-extraction wave.
- Requires `mob ~> 0.7`.
