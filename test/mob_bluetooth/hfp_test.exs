defmodule MobBluetooth.HfpTest do
  use ExUnit.Case, async: true

  alias MobBluetooth.Hfp

  describe "encode_vendor_at_opts/1" do
    test "default — empty company_ids list" do
      assert :json.decode(Hfp.encode_vendor_at_opts([])) == %{"company_ids" => []}
    end

    test "passes through a single company id" do
      assert :json.decode(Hfp.encode_vendor_at_opts(company_ids: [313])) == %{
               "company_ids" => [313]
             }
    end

    test "passes through several company ids in order" do
      assert :json.decode(Hfp.encode_vendor_at_opts(company_ids: [313, 76, 10])) == %{
               "company_ids" => [313, 76, 10]
             }
    end

    test "ignores unknown opts (forward-compatible)" do
      assert :json.decode(Hfp.encode_vendor_at_opts(company_ids: [313], extra: :ignored)) == %{
               "company_ids" => [313]
             }
    end
  end

  # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
  test "HFP connection events narrow the broadcast device to non-null" do
    bridge =
      Path.join([__DIR__, "..", "..", "priv", "native", "android", "MobBluetoothBridge.kt"])
      |> File.read!()

    [_, receiver_and_after] =
      String.split(bridge, "private fun ensureHfpConnectionReceiver", parts: 2)

    [receiver_source, _] =
      String.split(receiver_and_after, "fun bt_hfp_connect", parts: 2)

    assert receiver_source =~ "val device = if (Build.VERSION.SDK_INT >= 33)"
    refute receiver_source =~ "val device: BluetoothDevice?"
  end
end
