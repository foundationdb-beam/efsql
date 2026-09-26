defmodule Efsql.Settings do
  @moduledoc """
  The session settings `\\set` changes, shared by the line CLI and the TUI:

    * `limit` - the default row limit (15)
    * `tenant_batch` - how many tenants a `*.table` query reads per
      transaction; `off` (the default) reads them all in one
  """

  defstruct limit: 15, tenant_batch: nil

  @type t :: %__MODULE__{limit: pos_integer(), tenant_batch: pos_integer() | nil}

  @doc """
  Applies the text after `\\set `: `{:ok, settings, message}`, or
  `{:error, usage}` for an unknown setting or a bad value.
  """
  @spec set(t(), String.t()) :: {:ok, t(), String.t()} | {:error, String.t()}
  def set(%__MODULE__{} = settings, text) do
    case String.split(String.trim(text), ~r/\s+/, parts: 2) do
      ["limit", value] ->
        with {:ok, n} <- positive(value, "\\set limit N") do
          {:ok, %__MODULE__{settings | limit: n}, "limit set to #{n}"}
        end

      ["tenant_batch", "off"] ->
        {:ok, %__MODULE__{settings | tenant_batch: nil}, "tenant_batch off: one transaction"}

      ["tenant_batch", value] ->
        with {:ok, n} <- positive(value, "\\set tenant_batch N|off") do
          {:ok, %__MODULE__{settings | tenant_batch: n}, "tenant_batch set to #{n}"}
        end

      _ ->
        {:error, "usage: \\set limit N, or \\set tenant_batch N|off"}
    end
  end

  @doc "Each setting and its current value, for help text."
  @spec describe(t()) :: [{String.t(), String.t()}]
  def describe(%__MODULE__{} = settings) do
    [
      {"\\set limit N", "default row limit (#{settings.limit})"},
      {"\\set tenant_batch N|off",
       "tenants per transaction for *.table (#{settings.tenant_batch || "off"})"}
    ]
  end

  @doc "The query options for these settings (see `Efsql.Session.run/3`)."
  @spec query_options(t()) :: keyword()
  def query_options(%__MODULE__{tenant_batch: nil}), do: []
  def query_options(%__MODULE__{tenant_batch: n}), do: [tenant_batch: n]

  defp positive(value, usage) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, "usage: #{usage}"}
    end
  end
end
