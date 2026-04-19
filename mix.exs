defmodule Efsql.MixProject do
  use Mix.Project

  def project do
    [
      app: :efsql,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases(),
      aliases: aliases()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      mod: {Efsql.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ecto_foundationdb, path: "../ecto_foundationdb"},
      {:sql, github: "elixir-dbvisor/sql"},
      {:owl, "~> 0.13"},
      {:ex_fdbmonitor, "~> 0.1", only: :dev, runtime: false}
    ]
  end

  defp releases do
    [
      efsql: [
        include_executables_for: [:unix],
        strip_beams: false
      ]
    ]
  end

  defp aliases do
    []
  end
end
