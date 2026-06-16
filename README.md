# MobBluetooth

Bluetooth Classic (BR/EDR) plugin for [mob](https://github.com/genericjam/mob):
discovery, pairing, and HFP/HID/SPP profile sessions.

Extracted from mob in Wave 1 of the plugin epic. Provides the Elixir
wrappers around the Android Bluetooth Classic stack that previously
lived under `Mob.Bt.*` in mob core.

## Status

**Session A (this checkout):** Elixir-only extraction. The wrappers
call into mob's existing `:mob_nif.bt_*` NIF exports — the C/Zig NIF
code physically still lives in the mob repo for now.

**Session B (next):** the Android NIF (`android/jni/mob_nif.zig`)
and the iOS stubs (`ios/mob_nif.m`) move here too, the manifest
gains a `nifs:` declaration, and the plugin promotes to tier-1.

Until then, `mob_bluetooth` only works as a host-side declaration of
capabilities (Android permissions + iOS plist keys) plus the public
Elixir API surface.

## Modules

- `MobBluetooth` — device-level (list paired, discover, pair, unpair,
  disconnect)
- `MobBluetooth.Hfp` — Hands-Free Profile (audio + vendor AT commands)
- `MobBluetooth.Hid` — Human Interface Device (input reports)
- `MobBluetooth.Spp` — Serial Port Profile (RFCOMM byte streams)

## Installation

Add to your mob app's `mix.exs`:

```elixir
defp deps do
  [
    {:mob_bluetooth, path: "/path/to/mob_bluetooth"}
  ]
end
```

Then activate in `mob.exs`:

```elixir
config :mob, :plugins, [:mob_bluetooth]
```

Generate + sign + trust the plugin's signing key:

```bash
mix mob.plugin.keygen --plugin /path/to/mob_bluetooth
mix mob.plugin.sign   --plugin /path/to/mob_bluetooth
mix mob.plugin.trust mob_bluetooth
```

## Platform support

- **Android only.** iOS Bluetooth Classic requires Apple's MFi
  (paid, NDA-gated). All `MobBluetooth.*` functions return
  `{:error, :unsupported}` synchronously on iOS — the host app
  is responsible for guarding the call sites.
- For iOS-equivalent custom-hardware connectivity, use BLE
  (`Mob.Ble`, in mob core).

## Permissions

`mob_bluetooth`'s manifest declares the Android runtime permissions
the host app needs:

- `android.permission.BLUETOOTH_CONNECT` — pair, connect, disconnect
- `android.permission.BLUETOOTH_SCAN` — discovery

Request via `Mob.Permissions.request/2` at runtime before calling
into the API.

## Development

Clone, then run once:

```bash
mix setup
```

That fetches deps and activates the repo's git hooks (`.githooks/pre-push`):
`mix format --check`, `mix credo --strict` (incl. ExSlop), and `mix compile --warnings-as-errors` run on every push, plus the full test
suite when `mix.exs` changes — the same gate CI enforces before publishing.
