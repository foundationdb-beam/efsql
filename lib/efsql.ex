defmodule Efsql do
  @moduledoc """
  SQL frontend for EctoFoundationDB.

  A statement flows through the textbook pipeline:

      SQL text
        |> Efsql.Parser.to_logical()     # parse tree -> Efsql.Logical.Select
        |> resolve tenant
        |> Efsql.Rewrite.normalize()     # rewrite passes
        |> Efsql.Planner.plan()          # access-path selection -> Efsql.Physical.Plan
        |> Efsql.Executor.run()          # adapter pull + operator pipeline
  """

  import Ecto.Query

  def hello() do
    tenant = EctoFoundationDB.Tenant.open!(Efsql.Repo, "localhost")

    query = from(s in "secrets", select: [id: s.id, iv: s.iv])
    r1 = Efsql.Repo.all(query, prefix: tenant)

    r2 = all("select id, iv from localhost.secrets;")

    {r1, r2}
  end

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

  def stream(sql) do
    {logical, _tenants} = sql_to_logical(sql)
    query = logical |> Efsql.Rewrite.normalize() |> Efsql.Planner.to_ecto_query()
    {query, Efsql.Repo.stream(query)}
  end

  def sql_to_logical(sql, tenants \\ %{}) do
    logical = %Efsql.Logical.Select{} = Efsql.Parser.sql_to_logical(sql)
    resolve_tenant(logical, tenants)
  end

  def resolve_tenant(%Efsql.Logical.Select{prefix: {:all_tenants, _}}, _tenants) do
    raise Efsql.Exception.Unsupported, "a query across tenants can't be streamed"
  end

  # Already resolved, e.g. to the TUI session's active tenant.
  def resolve_tenant(%Efsql.Logical.Select{prefix: nil, tenant: tenant} = logical, tenants)
      when tenant != nil,
      do: {logical, tenants}

  def resolve_tenant(%Efsql.Logical.Select{} = logical, tenants) do
    {tenant_name, storage_id} =
      case logical.prefix do
        {storage_id, tenant_name} -> {tenant_name, storage_id}
        nil -> raise "Tenant required"
        tenant_name -> {tenant_name, nil}
      end

    if not Map.has_key?(tenants, {tenant_name, storage_id}) and
         not EctoFoundationDB.Tenant.exists?(Efsql.Repo, tenant_name) do
      raise Efsql.Exception.Unsupported, "Tenant '#{tenant_name}' does not exist"
    end

    {tenant, tenants} = open_tenant(tenants, tenant_name, storage_id)
    {%Efsql.Logical.Select{logical | tenant: tenant}, tenants}
  end

  @doc """
  Opens a tenant through the session's cache of open tenants, keyed by
  name and storage id (nil for the Repo's own).
  """
  def open_tenant(tenants, tenant_name, storage_id) do
    case Map.fetch(tenants, {tenant_name, storage_id}) do
      {:ok, tenant} ->
        {tenant, tenants}

      :error ->
        open_opts = if storage_id, do: [storage_id: storage_id], else: []

        # migrate: false keeps this read-only. Tenant.open/3 already requires
        # the tenant to exist (only open!/3 creates), so with the migration
        # step skipped efsql never writes to the database it is exploring.
        tenant =
          EctoFoundationDB.Tenant.open(Efsql.Repo, tenant_name, [migrate: false] ++ open_opts)

        {tenant, Map.put(tenants, {tenant_name, storage_id}, tenant)}
    end
  end
end
