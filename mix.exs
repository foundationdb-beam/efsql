defmodule Efsql.MixProject do
  use Mix.Project

  def project do
    [
      app: :efsql,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Efsql.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto_foundationdb, github: "foundationdb-beam/ecto_foundationdb"},
      {:sql, github: "elixir-dbvisor/sql"},
      {:io_ansi_table, "~> 1.0"}
    ]
  end
end
