defmodule MobBluetooth.Hid do
  @moduledoc """
  Bluetooth Classic Human Interface Device (HID) — input listener.

  Use this for Bluetooth keyboards, mice, gamepads, finger PTTs, scanners,
  presenter remotes, and any device that emits HID input reports
  (button/key/axis events) over Bluetooth.

  See `MobBluetooth` for pairing, discovery, and disconnect.

  ## Scope

  This module is **read-only** by design. HID hosts (phones) almost never
  send output reports to peripherals — that's a force-feedback /
  rumble-pack edge case. If your hardware genuinely needs output reports,
  open an issue.

  ## Typical flow

      # 1. Pair (MobBluetooth.pair/2)

      # 2. Connect HID profile.
      socket = MobBluetooth.Hid.connect(socket, device)
      # {:bt_hid, :connected, session_id, payload}

      # 3. Input reports stream as a decoded {type, code, value} map:
      # {:bt_hid, :input, session_id, %{type: integer, code: integer, value: integer}}

      # 4. Disconnect (MobBluetooth.disconnect/2)

  ## Input report shape

  Reports are decoded by the Android HID stack into usage-page +
  usage + value triples per the HID Usage Tables spec. Common pages:

    * `0x01` — Generic Desktop (mouse/joystick X/Y, wheel, etc.)
    * `0x07` — Keyboard/Keypad
    * `0x09` — Button (gamepad face buttons)
    * `0x0C` — Consumer (volume, play, mute, custom)
    * `0xFF00`–`0xFFFF` — Vendor-defined

  Multi-axis events arrive as separate messages, one per axis. Synthesize
  combined input on the receive side if needed.

  ## Receiving raw reports

  If the device's HID descriptor is non-standard or the high-level
  `{:bt_hid, :input, ...}` shape isn't sufficient, subscribe to raw reports
  with `subscribe_raw/2` and parse the bytes yourself.

  Stream: `{:bt_hid, :raw_report, session_id, bytes}` (a binary).
  """

  alias MobBluetooth

  @doc """
  Open an HID profile connection to `device`. The device must already be
  paired.

  Result: `{:bt_hid, :connected, session_id, payload}` on success,
  `{:bt_hid, :connect_failed, %{address: String.t(), reason: atom()}}`
  on failure (3-tuple — no session id exists yet).
  """
  @spec connect(socket :: term(), MobBluetooth.device()) :: term()
  def connect(socket, device) do
    if MobBluetooth.Platform.unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      json = MobBluetooth.encode_device(device)
      :mob_bluetooth_nif.bt_hid_connect(json)
      socket
    end
  end

  @doc """
  Subscribe to raw HID input reports (bypasses Android's parser).

  Use only when the device's HID descriptor is non-standard or the
  high-level `{:bt_hid, :input, ...}` events miss data you need.

  Stream: `{:bt_hid, :raw_report, session_id, bytes}` (a binary).
  """
  @spec subscribe_raw(socket :: term(), MobBluetooth.session_id()) :: term()
  def subscribe_raw(socket, session_id) when is_integer(session_id) do
    if MobBluetooth.Platform.unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.bt_hid_subscribe_raw(session_id)
      socket
    end
  end
end
