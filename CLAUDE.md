# mob_bluetooth — Agent Instructions

**Read [`AGENTS.md`](AGENTS.md) first**, then [`~/code/mob/AGENTS.md`](../mob/AGENTS.md) for the system view, and [`~/code/mob/MOB_PLUGINS.md`](../mob/MOB_PLUGINS.md) for the manifest schema. Together they cover the plugin anatomy, the three per-platform surfaces (Classic Android-only, BLE central iOS-only, BLE GATT peripheral cross-platform), and the cross-repo work with mob / mob_dev / mob_midi. This file goes deeper on Claude Code-specific workflow detail.

> **Keep AGENTS.md up to date** when you add a profile, change an event shape, add a native path, or hit a new gotcha. Out-of-date guidance there causes wrong decisions downstream — fix it in the same commit, not in a follow-up.

## What this repo is

A Mob plugin extracted from mob core (Wave 1/2 of the plugin epic) that wraps two different Bluetooth radios behind one Elixir surface: Bluetooth Classic (BR/EDR — Android-only) and Bluetooth Low Energy (BLE — cross-platform for the GATT peripheral, iOS-only for the central `ble_scan` / `ble_advertise`). Native is a single NIF module (`:mob_bluetooth_nif`) with two `platform:`-gated implementations: Zig on Android bridging to a plugin-owned Kotlin `MobBluetoothBridge`, ObjC on iOS wrapping CoreBluetooth.

## Pre-commit checklist

Before committing, run all in this order:

```bash
mix test                            # full suite must pass
mix format                          # apply formatting
mix credo --strict                  # whole tree, includes ExSlop + jump_credo_checks
```

Native changes (`.m` / `.zig` / `.kt`) aren't exercised by `mix test` — they need a `mix mob.deploy --native` of a host app (mob_plugin_demo is the canonical driver) and a real-device check before committing. Verified device set: **Moto G Power 2021** (Android reference) and **iPhone SE** (iOS BLE). Simulators / emulators have no radio.

The pre-push hook (`.githooks/pre-push`, activated via `git config core.hooksPath .githooks`) runs format/credo/compile on every push and the full suite when `mix.exs` changes (release preflight).

## Releases

`mix.exs` version bump on master triggers `.github/workflows/release.yml` (tag + GitHub Release + Hex publish, plus the pubkey-matches-signing-key check). See [`~/code/mob/RELEASE.md`](../mob/RELEASE.md) for the trigger model; do NOT bump versions without explicit permission.
