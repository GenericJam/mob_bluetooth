defmodule MobBluetooth.KotlinToolchain do
  @moduledoc false
  # The :kotlin tests compile the Android bridge's pure policy with kotlinc
  # against android-35 (the same SDK the -Werror compile gate uses) and run it
  # on a desktop JVM. They run wherever that toolchain exists and are excluded
  # elsewhere (e.g. CI without an Android SDK).

  @spec android_jar() :: Path.t() | nil
  def android_jar do
    sdk =
      System.get_env("ANDROID_HOME") || System.get_env("ANDROID_SDK_ROOT") ||
        Path.expand("~/Library/Android/sdk")

    jar = Path.join(sdk, "platforms/android-35/android.jar")
    if File.regular?(jar), do: jar
  end

  @spec available?() :: boolean()
  def available? do
    System.find_executable("kotlinc") != nil and System.find_executable("java") != nil and
      android_jar() != nil
  end
end

ExUnit.start(exclude: if(MobBluetooth.KotlinToolchain.available?(), do: [], else: [:kotlin]))
