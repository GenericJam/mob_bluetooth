defmodule MobBluetooth.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  One synchronous, read-only native call: `:mob_bluetooth_nif.bt_adapter_state/0`.
  It never scans, advertises, pairs or raises a permission prompt.

    * Android: the Zig NIF calls `MobBluetoothBridge.bt_adapter_state()` over
      the method id `nativeRegister` cached, which reads
      `BluetoothAdapter.getState()` (no runtime permission needed). An answer
      proves the NIF is linked, the Kotlin bridge registered and it holds an
      Activity.
    * iOS: the Objective-C NIF reads `CBManager.authorization`; only when the
      app is already allowed does it create a throwaway `CBCentralManager`
      (power alert off) and wait up to 3 s for its first state. An undecided
      authorization is answered without a manager, since creating one would
      prompt. On a simulator, where Bluetooth cannot be pre-granted (no
      `simctl privacy` service), expect `:not_determined`; an allowed one
      reports `:unsupported`.

  What each answer maps to:

    * `:on`, `:off`, `:turning_on`, `:turning_off`, `:resetting` → `:pass`.
      The radio exists and the native side reported it; whether it is
      switched on is the user's setting, not the plugin's health.
    * `:unsupported` → `{:skip, :needs_hardware}`: the native side reported
      no adapter (an Android device without `BluetoothManager.adapter`, the
      iOS Simulator once allowed).
    * `:unauthorized` (iOS: denied) and `:not_determined` (iOS: never asked)
      → `{:skip, :needs_user}`: the adapter state is behind a permission a
      person has to grant.
    * `:restricted` (iOS: Screen Time / MDM) → a string skip; nobody on the
      device can grant it.
    * `:no_activity` (Android: the bootstrap never handed the bridge an
      Activity), `{:error, :bridge_not_registered}` (`register()` never ran or
      the method id lookup failed), `{:error, :security_exception}` (Android:
      `getState()` threw, so the host manifest lost the install-time
      `BLUETOOTH` permission), any other `{:error, _}` and `:unknown` (iOS: no
      state report within 3 s) → `{:fail, _}`.

  The host stub's `nif_not_loaded` (the NIF is not linked into this build)
  is a failure too.
  """
  @behaviour Mob.Plugin.SelfTest

  @impl true
  def run(_ctx) do
    classify(:mob_bluetooth_nif.bt_adapter_state())
  rescue
    e in ErlangError ->
      {:fail,
       "mob_bluetooth_nif.bt_adapter_state/0 is not linked into this build: " <>
         Exception.message(e)}
  end

  @doc false
  # The classification of what bt_adapter_state/0 answered.
  @spec classify(term()) :: Mob.Plugin.SelfTest.result()
  def classify(state) when state in [:on, :off, :turning_on, :turning_off, :resetting],
    do: :pass

  def classify(:unsupported), do: {:skip, :needs_hardware}
  def classify(:unauthorized), do: {:skip, :needs_user}
  def classify(:not_determined), do: {:skip, :needs_user}

  def classify(:restricted),
    do:
      {:skip, "Bluetooth is restricted on this device (Screen Time or MDM); no user can grant it"}

  def classify(:no_activity),
    do: {:fail, "MobBluetoothBridge has no Activity (MobActivityAware.setActivity never called)"}

  def classify({:error, :bridge_not_registered}),
    do:
      {:fail,
       "Kotlin MobBluetoothBridge not registered (nativeRegister never ran or the " <>
         "bt_adapter_state method-ID lookup failed)"}

  def classify({:error, :security_exception}),
    do:
      {:fail,
       "BluetoothAdapter.getState() threw SecurityException: the host AndroidManifest " <>
         "lacks the install-time android.permission.BLUETOOTH the plugin manifest declares"}

  def classify(:unknown),
    do:
      {:fail,
       "bt_adapter_state/0 returned :unknown: the adapter reported no known state " <>
         "(iOS: no CBCentralManager state within 3 s)"}

  def classify(other),
    do:
      {:fail,
       "bt_adapter_state/0 returned #{inspect(other)}, expected an adapter state " <>
         "(:on, :off, :unsupported, ...)"}
end
