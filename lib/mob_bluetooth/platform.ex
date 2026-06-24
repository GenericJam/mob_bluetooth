defmodule MobBluetooth.Platform do
  @moduledoc false
  # Bluetooth Classic is Android-only (iOS needs Apple MFi). Pure predicate
  # so it's unit-testable without the NIF; the runtime platform comes from
  # :mob_nif.platform/0 (:ios | :android | :host).
  @spec unsupported?(atom()) :: boolean()
  def unsupported?(:ios), do: true
  def unsupported?(_), do: false

  # BLE (CoreBluetooth) is the inverse: iOS-only. The Android side of this plugin
  # wraps Bluetooth Classic (the bt_* surface) and does not implement the ble_*
  # NIFs, so `ble_*` is supported only on iOS for now.
  @spec ble_unsupported?(atom()) :: boolean()
  def ble_unsupported?(:ios), do: false
  def ble_unsupported?(_), do: true

  @spec current :: atom()
  def current, do: :mob_nif.platform()
end
