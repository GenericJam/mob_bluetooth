defmodule MobBluetooth.Le do
  @moduledoc """
  Bluetooth **Low Energy** (BLE) — GATT **peripheral** role.

  This is a different radio and role from the rest of `MobBluetooth`, which is
  Bluetooth Classic (BR/EDR) in the central/host role. Here the **phone is the
  peripheral**: it runs a GATT server, advertises a service, and a remote
  central (a laptop, another phone, a desktop's Bluetooth stack) connects to
  it. This is the piece BLE-MIDI, custom-accessory, and "expose data over BLE"
  use cases need.

  Unlike Classic, **BLE works on iOS without MFi** (CoreBluetooth's
  `CBPeripheralManager`), so `MobBluetooth.Le` is **cross-platform** — iOS and
  Android both supported; only the host (desktop dev) target is unsupported.

  ## Role & scope

  Peripheral / GATT-server only, for now: advertise one service with one or
  more characteristics, push notifications to subscribed centrals, and receive
  writes. BLE **central** (scanning for and connecting to other peripherals) is
  a separate, future addition.

  ## API style

  Same as the rest of Mob: callbacks return `socket` unchanged, results arrive
  in `handle_info/2`. LE events are tagged `:bt_le`:

      {:bt_le, :advertising_started}
      {:bt_le, :advertising_failed, %{reason: atom}}
      {:bt_le, :central_connected, %{central: integer}}
      {:bt_le, :central_disconnected, %{central: integer}}
      {:bt_le, :subscribed, %{characteristic: String.t()}}     # central enabled notifications
      {:bt_le, :unsubscribed, %{characteristic: String.t()}}
      {:bt_le, :write, %{characteristic: String.t(), bytes: binary}}  # central wrote to us

  `:central` is an opaque per-connection integer handle. Most peripherals (and
  BLE-MIDI in particular) can ignore it and treat the link as 1:1.

  ## Permissions

  Advertising requires `:bluetooth_advertise` on Android 12+ (API 31+), in
  addition to `:bluetooth_connect`. Request via `Mob.Permissions.request/2`
  before calling. iOS gates BLE behind the `NSBluetoothAlwaysUsageDescription`
  Info.plist key (declared by the plugin manifest).

  ## Example — advertise a service and push a notification

      service = %{
        local_name: "Mob Peripheral",
        service_uuid: "0000180D-0000-1000-8000-00805F9B34FB",
        characteristics: [
          %{uuid: "00002A37-0000-1000-8000-00805F9B34FB",
            properties: [:notify, :read]}
        ]
      }

      socket = MobBluetooth.Le.start_advertising(socket, service)
      # ... on {:bt_le, :subscribed, _} ...
      socket = MobBluetooth.Le.notify(socket, "00002A37-0000-1000-8000-00805F9B34FB", <<0x3C>>)
      # ... later ...
      socket = MobBluetooth.Le.stop_advertising(socket)
  """

  @typedoc """
  A GATT characteristic to expose. `:properties` is any subset of
  `:read`, `:write`, `:write_without_response`, `:notify`, `:indicate`.
  """
  @type characteristic :: %{
          required(:uuid) => String.t(),
          required(:properties) => [characteristic_property()]
        }

  @typedoc "A GATT characteristic property."
  @type characteristic_property ::
          :read | :write | :write_without_response | :notify | :indicate

  @typedoc "A GATT service to advertise as a peripheral."
  @type service :: %{
          required(:service_uuid) => String.t(),
          required(:characteristics) => [characteristic()],
          optional(:local_name) => String.t(),
          optional(:low_latency) => boolean()
        }

  @valid_properties [:read, :write, :write_without_response, :notify, :indicate]

  # ─────────────────────────────────────────────────────────────
  # Public API
  # ─────────────────────────────────────────────────────────────

  @doc """
  Start the GATT server and begin advertising `service` so a remote central can
  connect.

  Lifecycle arrives as `{:bt_le, :advertising_started}` or
  `{:bt_le, :advertising_failed, %{reason: atom}}`; connections as
  `{:bt_le, :central_connected, _}` / `{:bt_le, :central_disconnected, _}`.

  Set `:low_latency` to request a high-priority (low connection-interval)
  link — recommended for latency-sensitive payloads like MIDI. It's a hint;
  the OS and the central negotiate the actual interval.
  """
  @spec start_advertising(socket :: term(), service()) :: term()
  def start_advertising(socket, service) do
    if MobBluetooth.Platform.le_unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.ble_start_advertising(encode_advertise(service))
      socket
    end
  end

  @doc """
  Stop advertising and tear down the GATT server. Connected centrals are
  disconnected. Idempotent.
  """
  @spec stop_advertising(socket :: term()) :: term()
  def stop_advertising(socket) do
    if MobBluetooth.Platform.le_unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.ble_stop_advertising()
      socket
    end
  end

  @doc """
  Push `bytes` as a notification on the characteristic `char_uuid` to every
  subscribed central.

  No-op (on the native side) if no central has subscribed yet — wait for
  `{:bt_le, :subscribed, _}` before relying on delivery. The characteristic
  must have been declared with `:notify` (or `:indicate`).
  """
  @spec notify(socket :: term(), String.t(), binary()) :: term()
  def notify(socket, char_uuid, bytes)
      when is_binary(char_uuid) and is_binary(bytes) do
    if MobBluetooth.Platform.le_unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.ble_notify(char_uuid, bytes)
      socket
    end
  end

  # ─────────────────────────────────────────────────────────────
  # JSON encoding — exposed @doc false so tests can assert the wire shape
  # (the public functions dead-end in a NIF call). The service map is
  # normalised to the envelope the native bridges parse.
  # ─────────────────────────────────────────────────────────────

  @doc false
  @spec encode_advertise(service()) :: binary()
  def encode_advertise(service) do
    %{
      "local_name" => Map.get(service, :local_name, ""),
      "service_uuid" => fetch_uuid!(service, :service_uuid),
      "low_latency" => Map.get(service, :low_latency, false) == true,
      "characteristics" => encode_characteristics(Map.get(service, :characteristics, []))
    }
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defp encode_characteristics(chars) when is_list(chars) do
    Enum.map(chars, fn char ->
      %{
        "uuid" => fetch_uuid!(char, :uuid),
        "properties" => encode_properties(Map.get(char, :properties, []))
      }
    end)
  end

  defp encode_properties(props) when is_list(props) do
    Enum.map(props, fn prop ->
      unless prop in @valid_properties do
        raise ArgumentError,
              "invalid characteristic property #{inspect(prop)}; expected one of #{inspect(@valid_properties)}"
      end

      Atom.to_string(prop)
    end)
  end

  defp fetch_uuid!(map, key) do
    case Map.get(map, key) do
      uuid when is_binary(uuid) and uuid != "" ->
        uuid

      other ->
        raise ArgumentError,
              "expected a non-empty string for #{inspect(key)}, got #{inspect(other)}"
    end
  end
end
