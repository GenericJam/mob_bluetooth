# Changelog

All notable changes to **mob_bluetooth** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.3.2] - 2026-10-01

### Fixed

- **Android: `MobBluetooth.pair(socket, device, pin: "0000")` actually
  answers the pairing prompt now** (MOB-61). The Elixir side has
  documented programmatic PIN pairing for years
  (`lib/mob_bluetooth.ex:98-107,221-224`), but the Kotlin `bt_pair`
  read only `optString("address")` from the JSON — the `pin` field
  was dropped and the user got the system pairing dialog anyway. A
  new `ACTION_PAIRING_REQUEST` receiver, armed once when a caller
  supplies a `:pin`, calls `device.setPin(pin.toByteArray(UTF_8))`
  for `PAIRING_VARIANT_PIN` requests and `abortBroadcast()`s the
  system UI receiver. Passkey confirmation and OOB variants still
  fall through to the system dialog (they need a human).
  `setActivity` swap resets all lifecycle-owned receivers so a fresh
  Activity re-arms cleanly.

- **Android: HFP vendor-specific AT events from headsets without a
  plugin session no longer allocate phantom sessions** (MOB-195). The
  vendor-AT receiver used to fall back to `btSessionFor(dev)` for any
  headset that sent a vendor AT command, including headsets paired
  through system Settings. That leaked one `btSessionMap` entry per
  device for the app's lifetime. Events from devices with no existing
  session are now dropped; they had no subscriber pid to route to anyway.

- **Android: HFP now emits `:bt_hfp, :connected` for already-connected
  headsets (and, on Android ≤ 9, newly-initiated connects) and
  `:bt_hfp, :disconnected` for local + remote hang-ups**
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

  Also folded from the pre-commit review: every `connectedDevices()`
  call (in `bt_disconnect` and `bt_hfp_connect`) is now
  `SecurityException`-guarded (`BLUETOOTH_CONNECT` on API 31+). A
  missing grant no longer crashes the app from the main-thread proxy
  callback; `Hfp.connect` instead emits exactly one
  `{:bt_hfp, :connect_failed, %{reason: :permission_denied}}` and drops
  the session's pid mapping (a `SecurityException` from the reflective
  `connect()` maps to the same reason). A synchronous-`false` result from
  the reflective HFP `connect()` clears the session's pid mapping and
  emits `:connect_failed`, so callers get exactly one terminal event.

  **Platform limit:** since Android 10, `BluetoothHeadset.connect()` is
  restricted to privileged/system apps (`BLUETOOTH_PRIVILEGED`). For a
  normal app the call returns `false`, so `Hfp.connect/2` on a headset the
  system hasn't connected yields exactly one
  `{:bt_hfp, :connect_failed, %{reason: :hfp_connect_failed}}`. When the
  headset is already connected (through Settings or its own reconnect),
  `Hfp.connect/2` attaches a session and delivers `:connected` right
  away. Verified on Android 15 with a Monster Open Ear AC317:
  `:connected`, then a local `disconnect` giving exactly one `:local`,
  and link loss giving exactly one `:peer`.

- **Android: `pair` / `pair(pin:)` without `BLUETOOTH_CONNECT` now
  reply `{:bt, :pair_failed, %{reason: :permission_denied}}`** instead
  of no message (the unguarded `bondState` read threw before the
  guarded `createBond`). `unpair` reports `:permission_denied` instead
  of `:remove_bond_unavailable` for the same cause.

- **Android: SPP sessions emit exactly one `:bt_spp, :disconnected`.**
  A local `MobBluetooth.disconnect/2` used to emit `:remote` (from the
  read thread, whose read throws once the socket closes) and then
  `:local`. Whichever side removes the socket first now sends the only
  `:disconnected` event. If the peer's close wins that race, the
  `disconnect/2` caller gets `{:bt, :error, %{reason: :no_session}}`
  after the `:remote` event, instead of nothing. A remote close also
  retires the session id, unless HFP or a newer connection to the same
  device still uses it, so a later `disconnect(sid)` returns
  `{:bt, :error, %{reason: :no_session}}` instead of a synthetic second
  `:disconnected`.

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
  - Every `CallStaticVoidMethod` site (12 direct + 1 in `callBridgePidStr`,
    which fans out to 5 more via `bt_pair` / `bt_unpair` / `bt_hfp_connect`
    / `bt_spp_connect` / `ble_start_advertising`) calls
    `jni.exceptionClear(jenv)` immediately after the call — the JNI spec
    guarantees the clear is a no-op if no exception is pending.

  Existing runtime NIFs already guarded on a missing method-id cache via
  `if (g_bt.<method> == null) return btUnsupported(env);`, so the `:unsupported`
  path continues to work. Return-type contracts are unchanged; no public
  API change. iOS path is untouched.

---

## [0.3.1] - 2026-09-30

### Changed
- **Re-signed with plugin envelope v2** (MOB-287). mob_dev 0.7.2+ verifies
  this signature before evaluating the manifest. mob_dev 0.7.0 / 0.7.1 can't
  read v2 signatures and report this release as `invalid signature` —
  upgrade the host app to `{:mob_dev, "~> 0.7.2", only: :dev, runtime: false}`.
  No plugin code changes.
- Cut from the 0.3.0 tag: the Android fixes merged on master since 0.3.0 (MOB-61/62/63/64/195) await device verification and will ship in 0.3.2.

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
