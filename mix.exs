defmodule MobBluetooth.MixProject do
  use Mix.Project

  def project do
    [
      app: :mob_bluetooth,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:mob, path: "/Users/kevin/code/mob"}
    ]
  end
end
