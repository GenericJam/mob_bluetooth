defmodule MobBluetooth.SelfTestTest do
  use ExUnit.Case, async: true

  alias MobBluetooth.SelfTest
  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("../..", __DIR__)
  @zig Path.join(@plugin_dir, "priv/native/jni/mob_bluetooth_nif.zig")
  @objc Path.join(@plugin_dir, "priv/native/ios/mob_bluetooth_nif.m")
  @bridge Path.join(@plugin_dir, "priv/native/android/MobBluetoothBridge.kt")

  defp assert_result(result) do
    assert Mob.Plugin.SelfTest.result?(result), "not a SelfTest result: #{inspect(result)}"
    result
  end

  describe "run/1" do
    test "on a host with no native library linked it fails, naming the NIF, instead of raising" do
      for platform <- [:android, :ios] do
        assert {:fail, reason} =
                 assert_result(SelfTest.run(%{platform: platform, device: :emulator}))

        assert reason =~ "mob_bluetooth_nif.bt_adapter_state/0 is not linked"
        assert reason =~ "nif_not_loaded"
      end
    end
  end

  describe "classify/1" do
    test "every reported adapter state passes: the radio exists and native answered" do
      for state <- [:on, :off, :turning_on, :turning_off, :resetting] do
        assert assert_result(SelfTest.classify(state)) == :pass
      end
    end

    test "no adapter is a hardware skip" do
      assert assert_result(SelfTest.classify(:unsupported)) == {:skip, :needs_hardware}
    end

    test "a denied or undecided Bluetooth permission needs the user" do
      assert assert_result(SelfTest.classify(:unauthorized)) == {:skip, :needs_user}
      assert assert_result(SelfTest.classify(:not_determined)) == {:skip, :needs_user}
    end

    test "a restricted device is a skip nobody can clear, said in words" do
      assert {:skip, "Bluetooth is restricted" <> _} =
               assert_result(SelfTest.classify(:restricted))
    end

    test "host integration bugs fail" do
      assert {:fail, "MobBluetoothBridge has no Activity" <> _} =
               assert_result(SelfTest.classify(:no_activity))

      assert {:fail, "Kotlin MobBluetoothBridge not registered" <> _} =
               assert_result(SelfTest.classify({:error, :bridge_not_registered}))

      assert {:fail, "BluetoothAdapter.getState() threw SecurityException" <> _} =
               assert_result(SelfTest.classify({:error, :security_exception}))
    end

    test "an unknown state and anything off-contract fail, quoting the answer" do
      assert {:fail, "bt_adapter_state/0 returned :unknown" <> _} =
               assert_result(SelfTest.classify(:unknown))

      assert {:fail, "bt_adapter_state/0 returned {:error, :bridge_exception}" <> _} =
               assert_result(SelfTest.classify({:error, :bridge_exception}))

      assert {:fail, "bt_adapter_state/0 returned :ok" <> _} =
               assert_result(SelfTest.classify(:ok))

      assert {:fail, "bt_adapter_state/0 returned :unknown_authorization" <> _} =
               assert_result(SelfTest.classify(:unknown_authorization))
    end
  end

  describe "manifest" do
    test "declares the self-test, which passes the validator without a warning" do
      {:ok, m} = Manifest.load(@plugin_dir)
      assert m.selftest == MobBluetooth.SelfTest
      assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
      refute Enum.any?(warnings, &(&1 =~ "selftest"))
    end
  end

  describe "NIF stub agreement" do
    # The BEAM refuses to load a NIF library that registers a function the
    # module doesn't export, so a native table entry missing from the stub
    # breaks every call on that platform, not only the new one.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "every function either native side registers is exported by the stub" do
      exports = :mob_bluetooth_nif.module_info(:exports)

      zig =
        Regex.scan(~r/\.name = "(\w+)", \.arity = (\d+)/, File.read!(@zig),
          capture: :all_but_first
        )

      objc =
        Regex.scan(~r/^\s+\{"(\w+)", (\d+), nif_\w+,/m, File.read!(@objc),
          capture: :all_but_first
        )

      for {source, table} <- [zig: zig, objc: objc] do
        registered =
          for [name, arity] <- table, do: {String.to_atom(name), String.to_integer(arity)}

        assert {:bt_adapter_state, 0} in registered,
               "#{source} does not register bt_adapter_state/0"

        for fun <- registered do
          assert fun in exports, "#{source} registers #{inspect(fun)}, the stub doesn't export it"
        end
      end
    end

    # bt_adapter_state's Kotlin answer is an Int the Zig NIF decodes; a code
    # that drifts on one side makes the self-test misreport the adapter.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the Zig NIF decodes every MobBluetoothPolicy.ADAPTER_* code to its own term" do
      kotlin =
        Regex.scan(~r/const val ADAPTER_(\w+) = (\d+)/, File.read!(@bridge),
          capture: :all_but_first
        )

      [decoder] =
        Regex.run(~r/^fn adapterStateAtom\(.*?^}$/ms, File.read!(@zig))

      zig =
        ~r/^\s+(\d+) => erts\.(?:atom\(env, "(\w+)"\)|makeTuple\(env, \.\{ erts\.atom\(env, "error"\), erts\.atom\(env, "(\w+)"\))/m
        |> Regex.scan(decoder, capture: :all_but_first)
        |> Map.new(fn [code | atoms] -> {code, Enum.find(atoms, &(&1 != ""))} end)

      expected_name = %{"FAILED" => "bridge_exception"}

      for [name, code] <- kotlin do
        expected = Map.get(expected_name, name, String.downcase(name))
        assert zig[code] == expected, "ADAPTER_#{name} = #{code} decodes to #{inspect(zig[code])}"
      end

      # 0 is what CallStaticIntMethod returns when the Kotlin method threw.
      assert zig["0"] == "java_exception"
      assert map_size(zig) == length(kotlin) + 1
    end
  end
end
