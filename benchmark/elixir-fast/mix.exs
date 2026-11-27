defmodule Fast.MixProject do
  use Mix.Project

  def project do
    [app: :fast, version: "0.1.0", elixir: "~> 1.14", deps: deps()]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [{:postgrex, "~> 0.20"}]
  end
end
