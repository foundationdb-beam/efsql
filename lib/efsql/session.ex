defmodule Efsql.Session do
  @moduledoc """
  What a query runs in, for the line CLI and the TUI alike: the tenants
  opened so far (a cache, keyed by name and storage id), the `\\set`
  settings, and the active tenant and storage id, if any.

  A statement's scope comes from its table name and the session:

    * `tenant.table` or `storage_id.tenant.table` - that tenant
    * `table` - the active tenant (see `activate/3`)
    * `*.table` - every tenant of the active storage id, or of the Repo's
      when there is none; `storage_id.*.table` names one

  `run/3` returns an `Efsql.Result` and the session, whose tenant cache may
  have grown.
  """

  alias Efsql.Exception.Unsupported
  alias Efsql.Logical
  alias Efsql.Result
  alias Efsql.Settings

  defstruct tenants: %{},
            settings: %Settings{},
            tenant: nil,
            tenant_name: nil,
            storage_id: nil

  @type t :: %__MODULE__{
          tenants: map(),
          settings: Settings.t(),
          tenant: term() | nil,
          tenant_name: String.t() | nil,
          storage_id: String.t() | nil
        }

  @doc """
  Runs one statement. `options` go to the query on top of the settings'
  (see `Efsql.Fanout.plan/3` for the ones a query across tenants takes).
  """
  @spec run(t(), String.t(), keyword()) :: {Result.t(), t()}
  def run(%__MODULE__{} = session, sql, options \\ []) do
    started = System.monotonic_time(:millisecond)
    options = Keyword.merge(Settings.query_options(session.settings), options)

    {plan, rows, tenants} =
      sql
      |> Efsql.Parser.sql_to_logical()
      |> scope(session)
      |> Efsql.run_logical(options, session.tenants)

    elapsed = System.monotonic_time(:millisecond) - started
    {Result.new(plan, rows, elapsed), %__MODULE__{session | tenants: tenants}}
  end

  @doc """
  Makes a tenant the active one, for statements that don't name one. The
  tenant must exist in the storage id.
  """
  @spec activate(t(), String.t() | nil, String.t()) :: t()
  def activate(%__MODULE__{} = session, storage_id, tenant_name) do
    {tenant, tenants} =
      Efsql.open_tenant(session.tenants, tenant_name, storage_id, check_exists: true)

    %__MODULE__{
      session
      | tenant: tenant,
        tenant_name: tenant_name,
        storage_id: storage_id,
        tenants: tenants
    }
  end

  defp scope(%Logical.Select{prefix: {:all_tenants, nil}} = logical, session),
    do: %Logical.Select{logical | prefix: {:all_tenants, session.storage_id}}

  defp scope(%Logical.Select{prefix: nil}, %__MODULE__{tenant: nil}) do
    raise Unsupported,
          "no active tenant — qualify the table (tenant.table) or pick a tenant in the navigator"
  end

  defp scope(%Logical.Select{prefix: nil} = logical, session),
    do: %Logical.Select{logical | tenant: session.tenant}

  defp scope(logical, _session), do: logical
end
