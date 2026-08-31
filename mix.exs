defmodule Efsql.MixProject do
  use Mix.Project

  def project do
    [
      app: :efsql,
      version: "0.1.1",
      description: "SQL frontend and data explorer for FoundationDB",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      releases: releases(),
      aliases: aliases(),
      package: package()
    ]
  end

  defp package() do
    [
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => "https://github.com/foundationdb-beam/efsql"
      }
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
      {:ecto_foundationdb, github: "foundationdb-beam/ecto_foundationdb"},
      # Track the Ecto version ecto_foundationdb itself is developed against;
      # advance them together.
      {:ecto, "~> 3.13.0"},
      {:ex_fdbmonitor, github: "foundationdb-beam/ex_fdbmonitor", only: :dev, runtime: false},
      {:sql, github: "elixir-dbvisor/sql"},
      {:owl, "~> 0.13"}
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
