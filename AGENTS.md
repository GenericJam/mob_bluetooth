# mob_bluetooth — Agent Instructions

You're in **mob_bluetooth**, a Mob plugin for Bluetooth discovery, pairing, and profile sessions, extracted from mob core (Wave 1/2 of the plugin epic). It wraps two different radios sitting behind one Elixir surface: **Bluetooth Classic** (BR/EDR — Android-only) for `MobBluetooth`, `MobBluetooth.Hfp`, `MobBluetooth.Spp`; and **Bluetooth Low Energy** (BLE — CoreBluetooth on iOS, `BluetoothLeAdvertiser` / `BluetoothGattServer` on Android) for the `ble_*` central surface and the `MobBluetooth.Le` GATT peripheral.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view — the three-repo topology, plugin manifest schema, `Mob.Screen` / `Mob.Sigil`, driving a running app from your session, and the cross-cutting pre-empt-failure rules — and [`~/code/mob/MOB_PLUGINS.md`](../mob/MOB_PLUGINS.md) for the manifest schema. This file is mob_bluetooth-specific.

> **Keep this file current.** When you add a profile, change the event shape, add a native path, or hit a gotcha that would trip the next agent, fix it here in the same commit — not in a follow-up.

## What mob_bluetooth is, in one paragraph

Public surface is four modules — `MobBluetooth` (device-level: discovery, pairing, discoverability, the unified `disconnect/2`), `MobBluetooth.Hfp` (Hands-Free Profile: audio + vendor AT commands), `MobBluetooth.Spp` (Serial Port Profile: RFCOMM byte streams), and `MobBluetooth.Le` (BLE GATT peripheral: advertise a service, notify, receive writes). Plus the `ble_scan` / `ble_advertise` central-role helpers on `MobBluetooth` itself. Every function follows the Mob callback shape (return `socket` unchanged, results arrive as `handle_info/2` messages). Native is a single NIF module — `:mob_bluetooth_nif` — with two per-platform implementations behind a `platform:` gate in the manifest: Zig on Android bridging to a plugin-owned Kotlin `MobBluetoothBridge`, ObjC on iOS wrapping CoreBluetooth. `MobBluetooth.Platform` gates each surface per platform and returns `{:error, :unsupported}` synchronously off-target rather than reaching a NIF that doesn't exist.

## What mob_bluetooth is NOT

* **Not `mob_midi`.** MIDI-over-BLE is a specific GATT profile (service `03B80E5A-…`, characteristic `7772E5DB-…`, packet framing with a 13-bit ms timestamp) and it lives in `mob_midi`. `mob_bluetooth` provides the generic GATT peripheral primitive `mob_midi` builds on — do not duplicate the BLE-MIDI packet layer here.
* **Not Classic-only.** BLE is a first-class part of this plugin. `MobBluetooth.Le` (GATT peripheral) is the one surface that works on *both* platforms; the central-role `ble_scan` / `ble_advertise` helpers on `MobBluetooth` are iOS-only today.
* **Not BLE-only.** Classic (BR/EDR) discovery + pairing + HFP + SPP are the majority of the code and are Android-only. iOS Classic requires Apple MFi (a paid, NDA-gated program), so those functions return `{:error, :unsupported}` synchronously on iOS — this is a permanent platform asymmetry, not a TODO.
* **Not a HID host.** Receiving HID input from a paired keyboard / gamepad needs input-method / HID-host privileges Android denies ordinary apps. `MobBluetooth.Hid` does not exist and is not planned.
* **Not `mob_background`.** If you need to hold a BEAM alive so a Classic session can keep running while another app is foregrounded, that's `mob_background`'s foreground-service / silent-audio job. Do **not** reach for `mob_background` for BLE — the Apple-blessed path is the opt-in `ble_background_modes` config in the moduledoc, not audio keep-alive.

## The three surfaces, and where each works

Get this table right before you touch platform-gating code — the three predicates in `MobBluetooth.Platform` (`unsupported?`, `ble_unsupported?`, `le_unsupported?`) each guard a different surface.

| Surface | Elixir entry points | iOS | Android | host |
|---|---|---|---|---|
| Classic (BR/EDR) | `MobBluetooth.{list_paired, start_discovery, pair, unpair, make_discoverable, disconnect}` + `.Hfp.*` + `.Spp.*` | `{:error, :unsupported}` (MFi) | supported | `{:error, :unsupported}` |
| BLE central (scan + name advertise) | `MobBluetooth.{ble_scan, ble_stop_scan, ble_advertise, ble_stop_advertise}` | supported | `{:error, :unsupported}` (not implemented here yet) | `{:error, :unsupported}` |
| BLE GATT peripheral | `MobBluetooth.Le.{start_advertising, stop_advertising, notify}` | supported | supported | `{:error, :unsupported}` |

BLE needs a real radio, so nothing on the `ble_*` / `MobBluetooth.Le` rows works on the iOS Simulator or on the Android emulator's canonical images — the plugin *runs* fine (advertise-start events don't fail), but no peer will ever see the advert.

## Anatomy of the plugin

* `lib/mob_bluetooth.ex` — top-level `@moduledoc` (118 lines, canonical). Device-level Classic API + the `ble_*` central helpers. Read this first when a doc question comes up.
* `lib/mob_bluetooth/hfp.ex` — `MobBluetooth.Hfp`. `connect/2`, `subscribe_vendor_at/3`, `send_vendor_at/4`, `start_sco/2` / `stop_sco/2`. Emits `:bt_hfp` events.
* `lib/mob_bluetooth/spp.ex` — `MobBluetooth.Spp`. `connect/3` (with `:uuid` + `secure: false`), `write/3`. Emits `:bt_spp` events. Default UUID is the well-known SPP `00001101-0000-1000-8000-00805F9B34FB`.
* `lib/mob_bluetooth/le.ex` — `MobBluetooth.Le`. GATT peripheral (advertise a service, notify subscribed centrals, receive writes). Emits `:bt_le` events.
* `lib/mob_bluetooth/platform.ex` — the three platform predicates. `@moduledoc false`. Any new native surface needs a matching predicate here and a synchronous `{:error, :unsupported}` return on unsupported platforms — do not reach a NIF that isn't linked.
* `priv/mob_plugin.exs` — plugin manifest. Both NIF entries are the same module (`:mob_bluetooth_nif`) but `platform:`-gated: `lang: :zig, platform: :android` under `priv/native/jni/`, `lang: :objc, platform: :ios` under `priv/native/ios/`. Declares Android runtime + install-time permissions, iOS `CoreBluetooth` framework + `NSBluetoothAlwaysUsageDescription`, and (opt-in via `ble_background_modes` host config) `UIBackgroundModes`. Reads host config via `MobDev.Plugin.host_config/3` behind a `Code.ensure_loaded?/1` guard so the manifest still evaluates when mob_dev isn't loaded.
* `priv/native/jni/mob_bluetooth_nif.zig` — Android NIF (~1600 lines). All `bt_*` (Classic) and `ble_*` (BLE) atoms, constructors, `mob_deliver_*` exports, `nif_*` wrappers, method-id cache, dispatch table.
* `priv/native/jni/mob_bluetooth_jni.c` — the plain JNI thunks (`Java_io_mob_bluetooth_*`) the Kotlin bridge calls back through; each one hops to a `mob_deliver_bt_*` / `mob_deliver_ble_*` export in the Zig NIF.
* `priv/native/android/MobBluetoothBridge.kt` — plugin-owned Kotlin bridge (~1000 lines), package `io.mob.bluetooth`. Own class, **not** the app's `MobBridge`. mob_dev copies it into the app Kotlin source set and generates `MobPluginBootstrap.registerAll()` to call `MobBluetoothBridge.register()` at startup, which caches the jclass + method ids natively.
* `priv/native/ios/mob_bluetooth_nif.m` — iOS ObjC NIF (~800 lines). `CBCentralManager` for `ble_scan` / `ble_advertise` name-only advert, `CBPeripheralManager` for GATT peripheral (`MobBluetooth.Le`).
* `priv/mob_plugin.pub` + `priv/mob_plugin.sig` — Ed25519 plugin signature (see `.github/workflows/release.yml` for the CI check that the committed pubkey matches the signing key).
* `decisions/` — currently empty. Add an ADR when a non-obvious tradeoff comes up (e.g. next time you fight the 31-byte BLE advert size and decide to move the name into scan response, that's an ADR).

## Cross-repo work

**mob (framework):** `Mob.Permissions.request/2` is the sanctioned path to the `:bluetooth_connect` runtime permission — the bridge's `MobPermissionProvider` maps it per SDK (`MobBluetoothPolicy.bluetoothConnectPermissions`): `ACCESS_FINE_LOCATION` on API ≤ 30; the Android 12+ "Nearby devices" group (`SCAN` + `CONNECT` + `ADVERTISE`) on API 31+, plus `FINE` + `COARSE` location unless the host's `BLUETOOTH_SCAN` is `neverForLocation`. Core replies `:granted` only if *every* returned permission is granted, so never return a permission the running SDK doesn't define. Do not invent a second permissions surface here.

**mob_dev manifest schema limit:** `android.permissions` is a list of plain strings; mob_dev emits `<uses-permission android:name="…" />` with no attributes, so the plugin cannot declare `maxSdkVersion` / `usesPermissionFlags`. Hosts that want `neverForLocation` hand-declare the tags (README "Permissions"); the bridge reads the installed flags at runtime.

**mob_dev:** the Kotlin bridge copy, the `UIBackgroundModes` array merge (needs mob_dev ≥ 0.6.16 so it composes with e.g. `mob_background`'s `audio`), and the `MobPluginBootstrap.registerAll()` codegen all live there. When adding a native surface, check first that `MobDev.Plugin` copies your new files — the manifest schema is upstream.

**mob_midi:** `MobMidi.Ble` is a thin BLE-MIDI transport that sits on top of `MobBluetooth.Le.start_advertising/2` + `notify/3`. Only the two BLE-MIDI UUIDs and the packet framing (13-bit ms timestamp) live over there. If you find yourself adding a MIDI-specific concept to `MobBluetooth.Le`, it belongs in `mob_midi` instead.

## Testing

Elixir suite (host, no device needed):

```bash
mix deps.get
MIX_ENV=test mix test
```

Host tests cover pure code: manifest shape, JSON-encoding helpers (`encode_device`, `encode_pair`, `encode_connect`, `encode_advertise`, `scan_service_uuids`, `advertise_name`), platform predicates, and the `{:error, :unsupported}` return paths. **Every function that dead-ends in a NIF exposes its opt-normalisation as `@doc false` for a reason** — that's the unit-testable seam. Follow the pattern when you add a new one.

Native code is mostly not exercised by `mix test`. The exception is the bridge's **pure policy** (bottom of `MobBluetoothBridge.kt`: `MobBluetoothPolicy`, `BondWaiters`, `AdapterNameGuard` — no Android framework calls): `test/mob_bluetooth/android_policy_test.exs` compiles the bridge with `kotlinc` against `platforms/android-35/android.jar` and runs the scenarios in `test/kotlin/MobBluetoothPolicyTest.kt` on a desktop JVM. Those tests are tagged `:kotlin` and auto-excluded when `kotlinc` / `java` / the SDK jar are missing (CI). Put new decision logic there when you can, so it gets a real host test. Everything else needs a `mix mob.deploy --native` of a host app (mob_plugin_demo is the canonical driver) and a real device. **Verified device set:**

* **Moto G Power 2021** (`ZY22DP6HFL`, API 30 / Android 11) — Classic discovery + pair, HFP vendor AT (Hytera EHW02 PTT `+CTXD` / `+CUTXC`), SPP, BLE peripheral (`MobBluetooth.Le`) advert start + notify. This is the Android reference device; API 30 in particular exercises the *legacy install-time* `BLUETOOTH` / `BLUETOOTH_ADMIN` path that gets ignored on API 31+.
* **iPhone SE** — BLE peripheral (`MobBluetooth.Le`) via CoreBluetooth's `CBPeripheralManager`. Classic returns `{:error, :unsupported}` synchronously — that is the correct behaviour on iOS, not a bug to chase.

The iOS Simulator and Android emulator canonical images do not have radios. Advert-start events succeed; nobody ever sees the advert. Do not sign off a BLE change on a simulator.

## The pre-empt-failure rules that matter here

1. **Android runtime permissions are requested once, via `Mob.Permissions.request(socket, :bluetooth_connect)`.** The provider returns the per-SDK list above. Do not request `:bluetooth_scan` and `:bluetooth_connect` separately; users get two dialogs and the second one confuses them. Classic discovery needs `ACCESS_FINE_LOCATION` on API ≤ 30 and on 31+ without `neverForLocation` — `startDiscovery()` just returns `false` without it (logcat: `Permission denial: Need ACCESS_FINE_LOCATION permission to get scan results`), surfaced as `:location_permission_required`.
2. **API 30 and below need the *legacy* `BLUETOOTH` + `BLUETOOTH_ADMIN` install-time permissions or `adapter.isEnabled` throws `SecurityException`** — both are already in the manifest and auto-granted. Do not remove them thinking they're redundant on modern Android; they gate the *legacy* stack, not the runtime one.
3. **iOS Classic is `{:error, :unsupported}` forever.** MFi is a paid, NDA-gated program Kevin has not signed up for. Docs that hint the classic surface will "work later on iOS" are wrong — remove them.
4. **Background BLE is opt-in per app, not opt-out.** By default no `UIBackgroundModes` entry ships (Apple rejects apps declaring background modes they don't use). An app that needs it sets `config :mob_bluetooth, ble_background_modes: [:central | :peripheral | ...]` and the manifest merges the matching entry.
5. **Background BLE scanning silently drops without a `:service_uuids` filter.** iOS coalesces backgrounded scans, and an unfiltered one is dropped entirely — no error, no event, just nothing. `ble_scan(socket, service_uuids: [...])` is mandatory for the background path.
6. **The 31-byte legacy advertisement is a hard ceiling.** A 128-bit service UUID (16 B) plus a local name will not fit. Move the name into the scan-response packet (the 4-arg `startAdvertising`); the advert itself carries only the service UUID. Ignore this and you get `ADVERTISE_FAILED_DATA_TOO_LARGE`.
7. **Discovery is not pairing.** `start_discovery/1` returns nearby devices as `{:bt, :discovered, device}` — those devices are *not* bonded yet, and calling profile `connect/2` on one will fail. Pair with `MobBluetooth.pair/2` and wait for `{:bt, :paired, device}` before any profile-level call.
8. **OS power management suspends scans on both platforms.** iOS backgrounds coalesce; Android's Doze mode + OEM battery killers (Samsung, Xiaomi, Huawei) will kill a foreground scan the moment the screen turns off unless the app has a foreground service or is battery-optimisation-whitelisted. Docs that promise "continuous scanning" are lying — say "scanning while the app is foregrounded" and steer the user toward the background modes config for the rest.
9. **Synchronous prereq checks on the BEAM caller thread crash the whole app if they throw `SecurityException`.** Wrap every `adapter.isEnabled` / `adapter.startDiscovery` in the Kotlin bridge in `try/catch` and translate to `{:bt, :error, ...}` — do not let a Java exception unwind through the NIF (same class of bug as [[project_mob_nif_ui_thread_crash]]).

## Pre-commit checklist

Before committing, run all in this order:

```bash
mix test                            # full suite must pass
mix format                          # apply formatting
mix credo --strict                  # whole tree, includes ExSlop + jump_credo_checks
```

Native changes (`.m` / `.zig` / `.kt`) aren't exercised by `mix test` (beyond the `:kotlin` policy tests) — they need a `mix mob.deploy --native` of a host app (mob_plugin_demo is the canonical driver) and a real-device check on the verified device set (see Testing) before committing. Simulators / emulators have no radio.

Pre-push hook (`.githooks/pre-push`, activated via `git config core.hooksPath .githooks`) runs format/credo/compile on every push and the full suite when `mix.exs` changes (release preflight).

### Tests are part of the change

New behaviour ships with a test unless the change is small enough that a test would only restate it. For mob_bluetooth specifically:

* Any new opt-normalisation gets an `@doc false` helper and a unit test that exercises the empty / non-list / non-binary / negative-number branches — the pattern in `discoverable_duration/1`, `scan_service_uuids/1`, `advertise_name/1`, `encode_pair/2`.
* Any new event shape (a `:bt_*` / `:bt_hfp` / `:bt_spp` / `:bt_le` tag) gets called out in the module `@moduledoc` under "Events" alongside the existing ones — code that hides events from the docs breaks handler exhaustiveness in downstream apps.
* Any new native surface gets a matching predicate in `MobBluetooth.Platform` and a synchronous `{:error, :unsupported}` on unsupported platforms.

### Adversarial review

Spawn a subagent, point it at the diff, tell it to find defects rather than approve. Especially for this plugin:

* **Platform gating.** A new function that forgets its `Platform.*unsupported?` check will reach a NIF that isn't linked on the wrong platform and crash with `:undef` at runtime.
* **JSON encoding of `nil` values.** `encode_device/1` drops nil values on purpose — the Kotlin bridge's decoder rejects a `null`. New encoders must use the same `drop_nil_values` helper.
* **Kotlin exceptions on the BEAM thread.** See rule 9 above.
* **Event ordering.** BLE peripherals get `subscribed` before the first `notify/3` succeeds; a `notify/3` fired before that arrives is silently dropped by CoreBluetooth. Handler code that assumes otherwise will race.

## Release flow

Canonical process in [`~/code/mob/RELEASE.md`](../mob/RELEASE.md). mob_bluetooth specifics:

* `@version` in `mix.exs` is the trigger. Push it to master, `.github/workflows/release.yml` handles tag / GitHub Release / Hex publish, each step idempotent, and additionally verifies `MOB_PLUGIN_SIGN_KEY` matches the committed `priv/mob_plugin.pub` before publishing. Do NOT bump versions without explicit permission.
* The `mob` floor pin is load-bearing. Do not bump if the plugin uses a new mob feature that hasn't shipped yet.
* **Never ship without physical-device verification** on both the Moto G reference device (Classic + Android BLE) and the iPhone SE (iOS BLE). Simulators and emulators do not have radios; a "green on host + emulator" release is a release you didn't test.
