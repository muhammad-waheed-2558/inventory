defmodule Shop.MixProject do
  use Mix.Project

  def project do
    [
      app: :shop,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Starts the application supervision tree when `mix run` or `iex -S mix` is used.
  def application do
    [
      extra_applications: [:logger],
      mod: {Shop.Application, []}
    ]
  end

  defp deps do
    []
  end
end
