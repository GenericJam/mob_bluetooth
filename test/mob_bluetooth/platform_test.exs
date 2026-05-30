defmodule MobBluetooth.PlatformTest do
  use ExUnit.Case, async: true

  alias MobBluetooth.Platform

  describe "unsupported?/1" do
    test "iOS is unsupported (Bluetooth Classic needs Apple MFi)" do
      assert Platform.unsupported?(:ios) == true
    end

    test "Android is supported" do
      assert Platform.unsupported?(:android) == false
    end

    test "host is supported" do
      assert Platform.unsupported?(:host) == false
    end
  end
end
