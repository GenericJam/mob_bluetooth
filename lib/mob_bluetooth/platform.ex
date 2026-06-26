defmodule MobBluetooth.Platform do
  @moduledoc false
  # Bluetooth Classic is Android-only (iOS needs Apple MFi). Pure predicate
  # so it's unit-testable without the NIF; the runtime platform comes from
  # :mob_nif.platform/0 (:ios | :android | :host).
  @spec unsupported?(atom()) :: boolean()
  def unsupported?(:ios), do: true
  def unsupported?(_), do: false

  # BLE central scan + name advertise (the `ble_scan`/`ble_advertise` surface on
  # `MobBluetooth`) is iOS-only: the Android side wraps Bluetooth Classic and
  # doesn't implement those ble_* NIFs.
  @spec ble_unsupported?(atom()) :: boolean()
  def ble_unsupported?(:ios), do: false
  def ble_unsupported?(_), do: true

  # The BLE GATT *peripheral* surface (MobBluetooth.Le — advertise a service,
  # notify, receive writes) IS cross-platform: CBPeripheralManager on iOS (no
  # MFi), BluetoothGattServer on Android. Only the host dev target (no radio) is
  # unsupported.
  @spec le_unsupported?(atom()) :: boolean()
  def le_unsupported?(:host), do: true
  def le_unsupported?(_), do: false

  @spec current :: atom()
  def current, do: :mob_nif.platform()
end
