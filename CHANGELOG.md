# Changelog

All notable changes to **mob_bluetooth** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

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
