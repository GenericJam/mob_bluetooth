defmodule MobBluetoothTest do
  use ExUnit.Case, async: true

  alias MobBluetooth

  # The public surface of MobBluetooth + sub-profiles dead-ends in :mob_nif
  # calls, so the unit-testable layer is the JSON the Elixir side
  # hands to the NIF. The encoders are exposed `@doc false` for
  # exactly that reason — tested here, never advertised to users.

  describe "encode_device/1" do
    test "round-trips a minimal device map" do
      device = %{address: "AA:BB:CC:DD:EE:FF", name: "TestDev"}

      assert decoded(MobBluetooth.encode_device(device)) == %{
               "address" => "AA:BB:CC:DD:EE:FF",
               "name" => "TestDev"
             }
    end

    test "drops keys whose value is nil" do
      device = %{address: "AA:BB:CC:DD:EE:FF", name: "TestDev", bond_state: nil, uuids: nil}
      decoded = decoded(MobBluetooth.encode_device(device))
      assert Map.keys(decoded) |> Enum.sort() == ["address", "name"]
    end

    test "preserves a populated optional field" do
      device = %{
        address: "AA:BB:CC:DD:EE:FF",
        name: "TestDev",
        bond_state: :bonded,
        device_class: 1024,
        uuids: ["00001101-0000-1000-8000-00805F9B34FB"]
      }

      decoded = decoded(MobBluetooth.encode_device(device))
      assert decoded["bond_state"] == "bonded"
      assert decoded["device_class"] == 1024
      assert decoded["uuids"] == ["00001101-0000-1000-8000-00805F9B34FB"]
    end

    test "accepts a Keyword list and normalises it to a map" do
      assert decoded(MobBluetooth.encode_device(address: "AA:BB", name: "X")) == %{
               "address" => "AA:BB",
               "name" => "X"
             }
    end
  end

  describe "encode_pair/2" do
    test "without a PIN, output matches encode_device/1 byte-for-byte" do
      device = %{address: "AA:BB:CC:DD:EE:FF", name: "TestDev"}
      assert MobBluetooth.encode_pair(device, nil) == MobBluetooth.encode_device(device)
    end

    test "with a PIN, embeds it in the encoded payload" do
      device = %{address: "AA:BB:CC:DD:EE:FF", name: "TestDev"}
      decoded = decoded(MobBluetooth.encode_pair(device, "0000"))
      assert decoded["pin"] == "0000"
      assert decoded["address"] == "AA:BB:CC:DD:EE:FF"
    end
  end

  describe "make_discoverable (BLUETOOTH_ADVERTISE)" do
    @plugin_dir Path.expand("..", __DIR__)

    test "MobBluetooth exports make_discoverable/2" do
      assert {:make_discoverable, 2} in MobBluetooth.__info__(:functions)
    end

    test "discoverable_duration/1 defaults to 120 when no :duration is given" do
      assert MobBluetooth.discoverable_duration([]) == 120
    end

    test "discoverable_duration/1 passes a valid non-negative integer through" do
      assert MobBluetooth.discoverable_duration(duration: 60) == 60
      assert MobBluetooth.discoverable_duration(duration: 0) == 0
    end

    test "discoverable_duration/1 falls back to the default for invalid input" do
      assert MobBluetooth.discoverable_duration(duration: -5) == 120
      assert MobBluetooth.discoverable_duration(duration: "120") == 120
      assert MobBluetooth.discoverable_duration(duration: nil) == 120
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the NIF stub exports bt_make_discoverable/1 and is nif_not_loaded on host" do
      assert {:bt_make_discoverable, 1} in :mob_bluetooth_nif.module_info(:exports)

      assert_raise ErlangError, ~r/nif_not_loaded/, fn ->
        :mob_bluetooth_nif.bt_make_discoverable(120)
      end
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the manifest declares BLUETOOTH_ADVERTISE (needed by ACTION_REQUEST_DISCOVERABLE)" do
      assert File.read!(Path.join(@plugin_dir, "priv/mob_plugin.exs")) =~
               "android.permission.BLUETOOTH_ADVERTISE"
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the Android bridge fires ACTION_REQUEST_DISCOVERABLE from bt_make_discoverable" do
      src = File.read!(Path.join(@plugin_dir, "priv/native/android/MobBluetoothBridge.kt"))
      assert src =~ "fun bt_make_discoverable"
      assert src =~ "ACTION_REQUEST_DISCOVERABLE"
    end
  end

  describe "bluetooth_connect runtime permission capability" do
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the manifest registers the :bluetooth_connect capability" do
      {manifest, _} = Code.eval_file(Path.join(@plugin_dir, "priv/mob_plugin.exs"))
      caps = manifest |> Map.get(:permissions, []) |> Enum.map(& &1[:capability])
      assert :bluetooth_connect in caps
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the Android bridge is a MobPermissionProvider mapping :bluetooth_connect to the Nearby-devices group" do
      src = File.read!(Path.join(@plugin_dir, "priv/native/android/MobBluetoothBridge.kt"))
      assert src =~ "io.mob.plugin.MobPermissionProvider"
      assert src =~ "fun permissionsFor"
      assert src =~ "bluetooth_connect"

      for perm <- ~w(BLUETOOTH_CONNECT BLUETOOTH_SCAN BLUETOOTH_ADVERTISE) do
        assert src =~ "permission.#{perm}", "permissionsFor must request #{perm}"
      end
    end
  end

  defp decoded(json) when is_binary(json), do: :json.decode(json)
end
