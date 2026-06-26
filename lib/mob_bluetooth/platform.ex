defmodule MobBluetooth.Platform do
  @moduledoc false
  # Bluetooth Classic is Android-only (iOS needs Apple MFi). Pure predicate
  # so it's unit-testable without the NIF; the runtime platform comes from
  # :mob_nif.platform/0 (:ios | :android | :host).
  @spec unsupported?(atom()) :: boolean()
  def unsupported?(:ios), do: true
  def unsupported?(_), do: false

  # Bluetooth Low Energy (MobBluetooth.Le) is cross-platform: CoreBluetooth on
  # iOS needs no MFi, android.bluetooth.le on Android. Only the host dev target
  # (no radio) is unsupported.
  @spec le_unsupported?(atom()) :: boolean()
  def le_unsupported?(:host), do: true
  def le_unsupported?(_), do: false

  @spec current :: atom()
  def current, do: :mob_nif.platform()
end
