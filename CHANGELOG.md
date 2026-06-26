# Changelog

All notable changes to **mob_bluetooth** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- **Bluetooth Low Energy — GATT peripheral role (`MobBluetooth.Le`).** The phone
  can now run a GATT server, advertise a service, push notifications to
  subscribed centrals, and receive writes — i.e. present itself as a BLE device
  (sensor, accessory, BLE-MIDI peripheral) that a computer or another phone
  connects to. API: `start_advertising/2`, `stop_advertising/1`, `notify/3`;
  events tagged `:bt_le` (`:advertising_started` / `:advertising_failed`,
  `:central_connected` / `:central_disconnected`, `:subscribed` /
  `:unsubscribed`, `:write`).
- **First iOS native for this plugin.** BLE needs no MFi (unlike Classic), so
  `MobBluetooth.Le` is **cross-platform**: `CBPeripheralManager` on iOS
  (new `priv/native/ios/mob_bluetooth_nif.m`, `CoreBluetooth` framework),
  `BluetoothGattServer` + `BluetoothLeAdvertiser` on Android. Adds the
  `BLUETOOTH_ADVERTISE` permission (Android 12+).

  Scope: peripheral / GATT-server only. BLE **central** (scanning for and
  connecting to other peripherals) is a separate, future addition. The iOS
  central connect/disconnect events are approximated from subscribe/unsubscribe
  (CoreBluetooth's peripheral role exposes no raw connection callback).

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
