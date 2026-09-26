defmodule Efsql do
  @moduledoc """
  SQL frontend for EctoFoundationDB.

  A statement flows through the textbook pipeline:

      SQL text
        |> Efsql.Parser.sql_to_logical() # parse tree -> Efsql.Logical.Select
        |> resolve tenant
        |> Efsql.Rewrite.normalize()     # rewrite passes
        |> Efsql.Planner.plan()          # access-path selection -> Efsql.Physical.Plan
        |> Efsql.Executor.run()          # adapter pull + operator pipeline

  A query across tenants (`*.table`) is planned by `Efsql.Fanout` instead,
  which plans each tenant's read with `Efsql.Planner`.
  """

  def all(sql, options \\ []) do
    {_, result, _tenants} = qall(sql, options)
    result
  end

  def qall(sql, options \\ [], tenants \\ %{}) do
    sql |> Efsql.Parser.sql_to_logical() |> run_logical(options, tenants)
  end

  @doc """
  Plans and runs a translated query, resolving its tenant (or, for
  `*.table`, every tenant of the storage id) through the `tenants` cache.
  Returns `{plan, rows, tenants}`.
  """
  def run_logical(%Efsql.Logical.Select{prefix: {:all_tenants, _}} = logical, options, tenants) do
    {plan, tenants} =
      logical |> Efsql.Rewrite.normalize() |> Efsql.Fanout.plan(tenants, options)

    {plan, Efsql.Executor.run(plan), tenants}
  end

  def run_logical(%Efsql.Logical.Select{} = logical, options, tenants) do
    {logical, tenants} = resolve_tenant(logical, tenants)
    plan = logical |> Efsql.Rewrite.normalize() |> Efsql.Planner.plan(options)
    {plan, Efsql.Executor.run(plan), tenants}
  end

  # Already resolved, e.g. to the TUI session's active tenant.
  defp resolve_tenant(%Efsql.Logical.Select{prefix: nil, tenant: tenant} = logical, tenants)
       when tenant != nil,
       do: {logical, tenants}

  defp resolve_tenant(%Efsql.Logical.Select{} = logical, tenants) do
    {tenant_name, storage_id} =
      case logical.prefix do
        {storage_id, tenant_name} -> {tenant_name, storage_id}
        nil -> raise "Tenant required"
        tenant_name -> {tenant_name, nil}
      end

    {tenant, tenants} = open_tenant(tenants, tenant_name, storage_id, check_exists: true)
    {%Efsql.Logical.Select{logical | tenant: tenant}, tenants}
  end

  @doc """
  Opens a tenant through the session's cache of open tenants, keyed by
  name and storage id (nil for the Repo's own).

  Read-only: the tenant is opened with `migrate: false`, and
  `Tenant.open/3` only opens (never creates), so efsql never writes to the
  database it is exploring. A storage id other than the Repo's gets its
  tenant cache started first. With `check_exists: true`, a tenant that
  doesn't exist in that storage id is an `Efsql.Exception.Unsupported`
  error; tenants just listed from the storage id skip the check.
  """
  def open_tenant(tenants, tenant_name, storage_id, options \\ []) do
    case Map.fetch(tenants, {tenant_name, storage_id}) do
      {:ok, tenant} ->
        {tenant, tenants}

      :error ->
        if storage_id, do: Efsql.Discover.ensure_storage_cache(storage_id)
        config = Efsql.Repo.config()
        config = if storage_id, do: Keyword.put(config, :storage_id, storage_id), else: config

        if Keyword.get(options, :check_exists, false) and
             not EctoFoundationDB.Tenant.Backend.exists?(
               Ecto.Adapters.FoundationDB.db(Efsql.Repo),
               tenant_name,
               config
             ) do
          raise Efsql.Exception.Unsupported, "Tenant '#{tenant_name}' does not exist"
        end

        open_opts = if storage_id, do: [storage_id: storage_id], else: []

        tenant =
          EctoFoundationDB.Tenant.open(Efsql.Repo, tenant_name, [migrate: false] ++ open_opts)

        {tenant, Map.put(tenants, {tenant_name, storage_id}, tenant)}
    end
  end
end
