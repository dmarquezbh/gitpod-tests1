defmodule Platform.MixProject do
  use Mix.Project

  def project do
    [app: :platform, version: "0.1.0", elixir: "~> 1.14", deps: deps()]
  end

  def application do
    [extra_applications: [:logger], mod: {Platform.Application, []}]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 2.7"},
      {:postgrex, "~> 0.17"},
      {:jason, "~> 1.4"}
    ]
  end
end
