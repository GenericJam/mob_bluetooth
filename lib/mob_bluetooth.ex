defmodule MobBluetooth do
  @moduledoc """
  Bluetooth Classic (BR/EDR) — device-level discovery, pairing, and
  cross-profile session management.

  Profile-specific operations live in submodules:

    * `MobBluetooth.Hfp` — Hands-Free Profile (audio + vendor AT commands).
      Use this for headsets, PTT-equipped earpieces, etc.
    * `MobBluetooth.Spp` — Serial Port Profile (RFCOMM byte streams).
      Use this for legacy serial-over-Bluetooth devices (Arduino HC-05,
      OBD-II readers, marine GPS, industrial sensors).

  (HID is not supported on Android — receiving HID input requires
  input-method/HID-host privileges Android denies ordinary apps.)

  ## API style

  Same as the rest of Mob: callbacks return `socket` unchanged, results
  arrive in `handle_info/2` as messages. There are two families, and they
  do **not** share a uniform arity:

  **Device-level events** are tagged `:bt` and carry no session id:

      {:bt, :discovery_started}                  # 2-tuple, no payload
      {:bt, :discovery_finished}
      {:bt, :discovery_cancelled}
      {:bt, :discovered, device}                 # 3-tuple, device map
      {:bt, :paired, device}
      {:bt, :pair_failed, %{address: addr, reason: atom}}
      {:bt, :unpaired, device}
      {:bt, :paired_list, [device]}
      {:bt, :error, payload}

  **Profile events** are tagged by profile (`:bt_hfp`, `:bt_spp`) — not
  `:bt`. Once a session exists they carry its integer `session_id` as the
  third element; pre-session failures omit it:

      {:bt_hfp, :connected, session_id, payload}     # 4-tuple, has session
      {:bt_hfp, :connect_failed, %{address: addr, reason: atom}}  # 3-tuple, no session yet
      {:bt_hfp, :disconnected, session_id, reason}

  The profile submodules document their own event sets.

  ## Permissions

  Bluetooth requires runtime permissions on Android 12+ (API 31+):

    * `:bluetooth_scan` — for `start_discovery/1`
    * `:bluetooth_connect` — for `pair/2`, `connect/*`, `disconnect/2`

  Request via `Mob.Permissions.request/2` before calling MobBluetooth functions.

  ## iOS

  Bluetooth **Classic** on iOS requires Apple's MFi (Made for iPhone)
  certification — a paid, NDA-gated program — so the classic surface above
  (discovery, pairing, HFP, SPP) is **Android-only**: those functions return
  `{:error, :unsupported}` synchronously on iOS.

  iOS does expose **BLE** through CoreBluetooth, a separate, parallel protocol
  (a classic headset won't appear in a BLE scan, and vice versa). The `ble_*`
  functions — `ble_scan/1`, `ble_stop_scan/1`, `ble_advertise/2`,
  `ble_stop_advertise/1` — are **iOS-only** (they return `{:error, :unsupported}`
  on Android, which has no BLE surface in this plugin yet) and need a real radio,
  so they do nothing on the iOS Simulator.

  ### Background BLE

  Background BLE is **opt-in per app** — by default this plugin declares no
  background modes (foreground only), so apps that don't need it don't ship an
  unused background-mode declaration (Apple rejects those at review). To enable
  it, two things are needed:

    * Declare the mode(s) you use in your app config. Each adds the matching
      `UIBackgroundModes` entry to the host Info.plist (array-merged by
      mob_dev >= 0.6.16, alongside any existing entry such as `audio`):

          config :mob_bluetooth, ble_background_modes: [:central]              # background scanning/connecting
          config :mob_bluetooth, ble_background_modes: [:peripheral]           # background advertising
          config :mob_bluetooth, ble_background_modes: [:central, :peripheral] # both

    * Background **scanning requires a `:service_uuids` filter** —
      `ble_scan(socket, service_uuids: ["180D"])`. iOS silently drops an
      unfiltered scan once backgrounded, so a foreground-style
      `ble_scan(socket)` will not deliver in the background.

  iOS heavily throttles background BLE: scans are coalesced and de-duplicated
  (no repeat advertisement callbacks, slower RSSI), and background advertising
  drops the local name and moves service UUIDs to an overflow area only other
  iOS devices scanning for them can see. This is normal CoreBluetooth behaviour,
  not a plugin limitation. (Do not reach for the `mob_background` audio
  keep-alive for BLE — the dedicated background modes above are the Apple-blessed,
  review-safe path.)

  ## Pairing flow

  Two pairing modes, auto-selected by whether `:pin` is given:

      # System UI flow — Android shows a system pairing dialog
      socket = MobBluetooth.pair(socket, device)

      # Programmatic — PIN supplied via API, no UI
      socket = MobBluetooth.pair(socket, device, pin: "0000")

  If the programmatic PIN fails or the device requires UI confirmation
  (e.g. numeric comparison), Android falls back to the system UI
  automatically.

  ## Disconnect

  One canonical disconnect for any profile session:

      MobBluetooth.disconnect(socket, session_id)

  The framework looks up which profile owns the session_id and routes
  to the right profile-disconnect internally. Emits a profile-specific
  disconnect event (`{:bt_hfp, :disconnected, session_id, reason}` etc).
  """

  @typedoc "An opaque session identifier for an active profile connection."
  @type session_id :: pos_integer()

  @typedoc "A discovered or paired Bluetooth device."
  @type device :: %{
          required(:address) => String.t(),
          required(:name) => String.t(),
          optional(:bond_state) => :none | :bonding | :bonded,
          optional(:device_class) => non_neg_integer(),
          optional(:uuids) => [String.t()]
        }

  # ─────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────

  @doc """
  List currently paired (bonded) Bluetooth devices.

  Result arrives as `{:bt, :paired_list, [device]}`.
  """
  @spec list_paired(socket :: term()) :: term()
  def list_paired(socket) do
    if MobBluetooth.Platform.unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.bt_list_paired()
      socket
    end
  end

  @doc """
  Begin Bluetooth Classic discovery. Discovered devices arrive as
  individual `{:bt, :discovered, device}` messages, terminated by
  `{:bt, :discovery_finished}`.

  Discovery typically runs ~12 seconds on Android.
  """
  @spec start_discovery(socket :: term()) :: term()
  def start_discovery(socket) do
    if MobBluetooth.Platform.unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.bt_start_discovery()
      socket
    end
  end

  @doc """
  Cancel an in-progress discovery.
  """
  @spec cancel_discovery(socket :: term()) :: term()
  def cancel_discovery(socket) do
    if MobBluetooth.Platform.unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.bt_cancel_discovery()
      socket
    end
  end

  @default_discoverable_duration 120

  @doc """
  Request that the device become discoverable to nearby Bluetooth devices for
  `:duration` seconds (default #{@default_discoverable_duration}). Shows the
  system "make discoverable?" dialog.

  An invalid `:duration` (missing, non-integer, or negative) falls back to the
  default; the platform bounds the upper end. Requires the `BLUETOOTH_ADVERTISE`
  runtime permission (the Android 12+ "Nearby devices" group) — request it
  before calling. Fire-and-forget: the system dialog is the user-facing result;
  the accept/deny outcome is not captured today. A failure (adapter off,
  permission not granted) arrives as `{:bt, :error, reason}`.
  """
  @spec make_discoverable(socket :: term(), keyword()) :: term()
  def make_discoverable(socket, opts \\ []) do
    if MobBluetooth.Platform.unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.bt_make_discoverable(discoverable_duration(opts))
      socket
    end
  end

  @doc false
  # Normalise the `:duration` opt to a non-negative integer of seconds, falling
  # back to the default for a missing/non-integer/negative value. Pure, so the
  # opt handling is unit-testable without the device NIF.
  @spec discoverable_duration(keyword()) :: non_neg_integer()
  def discoverable_duration(opts) do
    case Keyword.get(opts, :duration, @default_discoverable_duration) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @default_discoverable_duration
    end
  end

  @doc """
  Pair (bond) with a Bluetooth device.

  Without `:pin`, Android shows the system pairing dialog (user enters
  PIN). With `:pin`, attempts programmatic pairing using the supplied
  PIN; falls back to system UI if the device demands user confirmation.

  Result arrives as one of:

    * `{:bt, :paired, device}`
    * `{:bt, :pair_failed, %{address: String.t(), reason: atom()}}`
  """
  @spec pair(socket :: term(), device(), keyword()) :: term()
  def pair(socket, device, opts \\ []) do
    if MobBluetooth.Platform.unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      pin = Keyword.get(opts, :pin)
      json = encode_pair(device, pin)
      :mob_bluetooth_nif.bt_pair(json)
      socket
    end
  end

  @doc """
  Remove an existing pairing (bond).

  Result: `{:bt, :unpaired, device}`.
  """
  @spec unpair(socket :: term(), device()) :: term()
  def unpair(socket, device) do
    if MobBluetooth.Platform.unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      json = encode_device(device)
      :mob_bluetooth_nif.bt_unpair(json)
      socket
    end
  end

  @doc """
  Disconnect a profile session by `session_id`.

  Works for any profile (`MobBluetooth.Hfp`, `MobBluetooth.Spp`) — the
  framework dispatches internally based on which profile owns the session.

  Emits a profile-specific disconnect event:

    * `{:bt_hfp, :disconnected, session_id, reason}`
    * `{:bt_spp, :disconnected, session_id, reason}`
  """
  @spec disconnect(socket :: term(), session_id()) :: term()
  def disconnect(socket, session_id) when is_integer(session_id) do
    if MobBluetooth.Platform.unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.bt_disconnect(session_id)
      socket
    end
  end

  # ── BLE (CoreBluetooth) — iOS only ────────────────────────────────────────
  # A separate, parallel surface from the classic bt_* functions above. iOS has
  # no public classic-BT API; BLE is what CoreBluetooth exposes. Each ble_*
  # function returns `{:error, :unsupported}` off iOS (no Android BLE yet).

  @default_advertise_name "Mob"

  @doc """
  Scan for nearby BLE peripherals (iOS / CoreBluetooth).

  Pass `:service_uuids` (a list of service-UUID strings, e.g.
  `["180D", "0000180F-0000-1000-8000-00805F9B34FB"]`) to filter the scan.
  Omitting it scans for everything, which works in the foreground but **not in
  the background** — iOS silently drops an unfiltered scan once the app is
  backgrounded, so a service-UUID filter is required for background scanning
  (see "Background BLE" in the moduledoc).

  Emits, to the calling process (same `:bt` device-event family as classic
  discovery):

    * `{:bt, :ble_scan_started}`
    * `{:bt, :ble_device, %{id: uuid, name: name | nil, rssi: integer}}`
      (once per advertisement seen)
    * `{:bt, :error, %{reason: atom}}` if the radio is off/unauthorized.

  iOS only — `{:error, :unsupported}` elsewhere. BLE needs a real radio, so it
  does nothing on the iOS Simulator.
  """
  @spec ble_scan(socket :: term(), keyword()) :: term()
  def ble_scan(socket, opts \\ []) do
    if MobBluetooth.Platform.ble_unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.ble_scan(scan_service_uuids(opts))
      socket
    end
  end

  @doc false
  # Normalise the `:service_uuids` opt to a list of binaries (dropping anything
  # non-binary). Pure, so the opt handling is unit-testable without the NIF.
  @spec scan_service_uuids(keyword()) :: [binary()]
  def scan_service_uuids(opts) do
    opts
    |> Keyword.get(:service_uuids, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  @doc """
  Stop a BLE scan. Emits `{:bt, :ble_scan_stopped}`. iOS only.
  """
  @spec ble_stop_scan(socket :: term()) :: term()
  def ble_stop_scan(socket) do
    if MobBluetooth.Platform.ble_unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.ble_stop_scan()
      socket
    end
  end

  @doc """
  Advertise this device as a BLE peripheral with a local `:name`
  (default #{inspect(@default_advertise_name)}) — the BLE analog of
  `make_discoverable/2`.

  Emits `{:bt, :ble_advertising}` once advertising starts, or
  `{:bt, :error, %{reason: atom}}`. iOS only — `{:error, :unsupported}`
  elsewhere.
  """
  @spec ble_advertise(socket :: term(), keyword()) :: term()
  def ble_advertise(socket, opts \\ []) do
    if MobBluetooth.Platform.ble_unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.ble_advertise(advertise_name(opts))
      socket
    end
  end

  @doc """
  Stop BLE advertising. Emits `{:bt, :ble_advertise_stopped}`. iOS only.
  """
  @spec ble_stop_advertise(socket :: term()) :: term()
  def ble_stop_advertise(socket) do
    if MobBluetooth.Platform.ble_unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.ble_stop_advertise()
      socket
    end
  end

  @doc false
  # Normalise the advertised `:name` to a non-empty binary, falling back to the
  # default for a missing/blank/non-binary value. Pure, so it's unit-testable
  # without the device NIF.
  @spec advertise_name(keyword()) :: binary()
  def advertise_name(opts) do
    case Keyword.get(opts, :name, @default_advertise_name) do
      name when is_binary(name) ->
        if String.trim(name) == "", do: @default_advertise_name, else: name

      _ ->
        @default_advertise_name
    end
  end

  # Internal JSON helpers, exposed `@doc false` so the test suite can
  # exercise the encoded shape directly (the public functions all dead-end
  # in a NIF call). Nil-safe per the VendorUsb playbook.
  # ─────────────────────────────────────────────────────────────

  @doc false
  @spec encode_pair(device(), String.t() | nil) :: binary()
  def encode_pair(device, nil), do: encode_device(device)

  def encode_pair(device, pin) when is_binary(pin) do
    device |> Map.put(:pin, pin) |> encode_device()
  end

  @doc false
  @spec encode_device(map()) :: binary()
  def encode_device(device) do
    device
    |> Map.new()
    |> drop_nil_values()
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp drop_nil_values(map) do
    :maps.filter(fn _k, v -> v != nil end, map)
  end
end
