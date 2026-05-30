defmodule MobBluetooth.Platform do
  @moduledoc false
  # Bluetooth Classic is Android-only (iOS needs Apple MFi). Pure predicate
  # so it's unit-testable without the NIF; the runtime platform comes from
  # :mob_nif.platform/0 (:ios | :android | :host).
  @spec unsupported?(atom()) :: boolean()
  def unsupported?(:ios), do: true
  def unsupported?(_), do: false

  @spec current :: atom()
  def current, do: :mob_nif.platform()
end
