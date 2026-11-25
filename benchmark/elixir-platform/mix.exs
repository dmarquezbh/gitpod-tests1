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
      {:plug_cowboy, "~> 2.6.0"},
      {:plug, "~> 1.14.0", override: true},
      {:postgrex, "~> 0.17.0"},
      {:db_connection, "~> 2.5.0", override: true},
      {:jason, "~> 1.4"},
      {:ranch, "~> 1.8", override: true}
    ]
  end
end
