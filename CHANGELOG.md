# Changelog

All notable changes to **mob_bluetooth** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

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
