defmodule MobBluetooth.Hfp do
  @moduledoc """
  Bluetooth Classic Hands-Free Profile (HFP) — audio + vendor AT commands.

  Use this for headsets, PTT-equipped earpieces (Hytera EHW02, etc), and
  any device that exposes an HFP control link plus an SCO audio link.

  See `MobBluetooth` for pairing, discovery, and disconnect — those are
  device-level concerns. Profile-specific operations live here.

  ## Typical flow

      # 1. Pair (only needed once per device — MobBluetooth.pair/2)
      socket = MobBluetooth.pair(socket, device)
      # {:bt, :paired, device}

      # 2. Connect HFP profile
      socket = MobBluetooth.Hfp.connect(socket, device)
      # {:bt_hfp, :connected, session_id, payload}

      # 3. (Optional) subscribe to vendor AT commands the headset emits.
      #    Hytera EHW02 fires +CTXD on PTT press, +CUTXC on release.
      socket = MobBluetooth.Hfp.subscribe_vendor_at(socket, session_id)
      # {:bt_hfp, :vendor_at, session_id, %{cmd: "+CTXD", args: ""}}

      # 4. (Optional) bring up the SCO audio link (audio then routes through
      #    Android's normal in-call path; see "SCO audio" below).
      socket = MobBluetooth.Hfp.start_sco(socket, session_id)
      # {:bt_hfp, :sco_started, session_id, %{address: ...}}

      # 5. Disconnect (one canonical path — MobBluetooth.disconnect/2)
      MobBluetooth.disconnect(socket, session_id)

  ## Vendor AT commands

  HFP defines a small core AT vocabulary (call control, volume, ring).
  Headset vendors extend with their own `+`-prefixed commands. Subscribing
  via `subscribe_vendor_at/2` delivers any *unrecognized* AT command from
  the headset as `{:bt_hfp, :vendor_at, session_id, %{cmd, args}}` for your
  app to interpret.

  Sending a vendor AT command to the headset is `send_vendor_at/4`.
  Standard responses (`OK`, `ERROR`) are emitted by Android automatically —
  use the `response` argument to override only when the AT spec demands
  custom payload.

  ## SCO audio (link control only)

  SCO (Synchronous Connection-Oriented) is the real-time bidirectional
  voice channel HFP uses for call audio. `start_sco/2` brings the link up
  (via `startScoUsingVirtualVoiceCall` + `MODE_IN_COMMUNICATION`) and
  `stop_sco/2` tears it down.

  > #### Audio is not streamed through events {: .info}
  >
  > Once the SCO link is up, audio flows through Android's normal in-call
  > audio routing (the headset becomes the active mic/speaker). Raw PCM is
  > **not** delivered to the BEAM as events, and the codec parameters
  > (sample rate / mSBC vs CVSD) are not surfaced — `:sco_started` carries
  > only the device address. Forwarding PCM frames as `{:bt_hfp, :sco_audio,
  > ...}` events would be net-new work; it has never been implemented (true
  > in mob core as well).
  """

  alias MobBluetooth

  @doc """
  Open an HFP profile connection to `device`. The device must already
  be paired (`MobBluetooth.pair/2`).

  Result: `{:bt_hfp, :connected, session_id, payload}` on success,
  `{:bt_hfp, :connect_failed, %{address: String.t(), reason: atom()}}`
  on failure (3-tuple — no session id exists yet).
  """
  @spec connect(socket :: term(), MobBluetooth.device()) :: term()
  def connect(socket, device) do
    if MobBluetooth.Platform.unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      json = MobBluetooth.encode_device(device)
      :mob_bluetooth_nif.bt_hfp_connect(json)
      socket
    end
  end

  @doc """
  Subscribe to vendor-specific AT commands emitted by the headset on the
  given HFP session.

  The caller specifies which BT SIG company IDs to listen for via the
  `:company_ids` option. Android's ACTION_VENDOR_SPECIFIC_HEADSET_EVENT
  broadcasts are only delivered for explicitly-registered IDs, so a
  default empty list means no events will be received.

  Common values:

    * `313`  — Hytera (PTT commercial radios)
    * `76`   — Apple (AirPods custom events)
    * `10`   — Qualcomm
    * `1117` — Plantronics / Poly

  Standard (non-vendor) AT commands are handled by Android's HFP stack
  and never surface here.

  Stream events: `{:bt_hfp, :vendor_at, session_id, %{cmd: String.t(), cmd_type: integer(), args: String.t(), address: String.t()}}`.

  ## Example

      MobBluetooth.Hfp.subscribe_vendor_at(socket, session_id, company_ids: [313])
  """
  @spec subscribe_vendor_at(socket :: term(), MobBluetooth.session_id(), keyword()) :: term()
  def subscribe_vendor_at(socket, session_id, opts \\ [])
      when is_integer(session_id) and is_list(opts) do
    if MobBluetooth.Platform.unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      json = encode_vendor_at_opts(opts)
      :mob_bluetooth_nif.bt_hfp_subscribe_vendor_at(session_id, json)
      socket
    end
  end

  @doc false
  @spec encode_vendor_at_opts(keyword()) :: binary()
  def encode_vendor_at_opts(opts) when is_list(opts) do
    company_ids = Keyword.get(opts, :company_ids, [])

    %{company_ids: company_ids}
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  @doc """
  Send a vendor AT command to the headset. Useful for headset-specific
  feature toggles or query/response protocols.

      MobBluetooth.Hfp.send_vendor_at(socket, session, "+XAPL", "0505,2")
  """
  @spec send_vendor_at(socket :: term(), MobBluetooth.session_id(), String.t(), String.t()) ::
          term()
  def send_vendor_at(socket, session_id, cmd, args \\ "")
      when is_integer(session_id) and is_binary(cmd) and is_binary(args) do
    if MobBluetooth.Platform.unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.bt_hfp_send_vendor_at(session_id, cmd, args)
      socket
    end
  end

  @doc """
  Open the SCO audio link for this HFP session.

  Emits `{:bt_hfp, :sco_started, session_id, %{address: String.t()}}` when the
  link is up; on failure `{:bt_hfp, :error, session_id, reason}`. Audio then
  routes through Android's normal in-call path — PCM is not delivered as
  events (see the "SCO audio" section in the module doc).
  """
  @spec start_sco(socket :: term(), MobBluetooth.session_id()) :: term()
  def start_sco(socket, session_id) when is_integer(session_id) do
    if MobBluetooth.Platform.unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.bt_hfp_start_sco(session_id)
      socket
    end
  end

  @doc """
  Close the SCO audio link without disconnecting the HFP session.

  Emits `{:bt_hfp, :sco_stopped, session_id}` (3-tuple).
  """
  @spec stop_sco(socket :: term(), MobBluetooth.session_id()) :: term()
  def stop_sco(socket, session_id) when is_integer(session_id) do
    if MobBluetooth.Platform.unsupported?(MobBluetooth.Platform.current()) do
      {:error, :unsupported}
    else
      :mob_bluetooth_nif.bt_hfp_stop_sco(session_id)
      socket
    end
  end
end
