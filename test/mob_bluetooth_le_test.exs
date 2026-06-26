defmodule MobBluetooth.LeTest do
  use ExUnit.Case, async: true

  alias MobBluetooth.Le
  alias MobBluetooth.Platform

  # Like the Classic suite, the public surface dead-ends in :mob_nif calls, so
  # the unit-testable layer is the advertise JSON the Elixir side builds. The
  # encoder is exposed `@doc false` for exactly that.

  @midi_service "03B80E5A-EDE8-4B33-A751-6CE34EC4C700"
  @midi_char "7772E5DB-3868-4112-A1A9-F2669D106BF3"

  describe "encode_advertise/1" do
    test "round-trips a full service with characteristics and properties" do
      service = %{
        local_name: "Mob MIDI",
        service_uuid: @midi_service,
        low_latency: true,
        characteristics: [
          %{uuid: @midi_char, properties: [:notify, :write_without_response, :read]}
        ]
      }

      assert decoded(Le.encode_advertise(service)) == %{
               "local_name" => "Mob MIDI",
               "service_uuid" => @midi_service,
               "low_latency" => true,
               "characteristics" => [
                 %{
                   "uuid" => @midi_char,
                   "properties" => ["notify", "write_without_response", "read"]
                 }
               ]
             }
    end

    test "defaults local_name to empty and low_latency to false" do
      decoded =
        decoded(
          Le.encode_advertise(%{
            service_uuid: @midi_service,
            characteristics: [%{uuid: @midi_char, properties: [:notify]}]
          })
        )

      assert decoded["local_name"] == ""
      assert decoded["low_latency"] == false
    end

    test "coerces a truthy-but-non-true low_latency to a strict boolean" do
      decoded =
        decoded(
          Le.encode_advertise(%{
            service_uuid: @midi_service,
            low_latency: "yes",
            characteristics: []
          })
        )

      assert decoded["low_latency"] == false
    end

    test "supports multiple characteristics" do
      decoded =
        decoded(
          Le.encode_advertise(%{
            service_uuid: @midi_service,
            characteristics: [
              %{uuid: @midi_char, properties: [:notify]},
              %{uuid: "00002A37-0000-1000-8000-00805F9B34FB", properties: [:read, :indicate]}
            ]
          })
        )

      assert length(decoded["characteristics"]) == 2
    end

    test "raises on a missing or empty service_uuid" do
      assert_raise ArgumentError, fn ->
        Le.encode_advertise(%{characteristics: []})
      end

      assert_raise ArgumentError, fn ->
        Le.encode_advertise(%{service_uuid: "", characteristics: []})
      end
    end

    test "raises on a missing characteristic uuid" do
      assert_raise ArgumentError, fn ->
        Le.encode_advertise(%{
          service_uuid: @midi_service,
          characteristics: [%{properties: [:notify]}]
        })
      end
    end

    test "raises on an unknown characteristic property" do
      assert_raise ArgumentError, fn ->
        Le.encode_advertise(%{
          service_uuid: @midi_service,
          characteristics: [%{uuid: @midi_char, properties: [:teleport]}]
        })
      end
    end
  end

  describe "Platform.le_unsupported?/1" do
    test "LE is supported on iOS and Android, unsupported only on host" do
      assert Platform.le_unsupported?(:host)
      refute Platform.le_unsupported?(:ios)
      refute Platform.le_unsupported?(:android)
    end
  end

  defp decoded(json) when is_binary(json), do: :json.decode(json)
end
