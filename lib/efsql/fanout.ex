defmodule Efsql.Fanout do
  @moduledoc """
  Plans a query across every tenant of a storage id (`*.table` or
  `storage_id.*.table`). Tenants of one storage id share their schema,
  which is what makes one query over all of them meaningful.

  Predicates on `_tenant` never reach the database: they pick the tenants
  to read, from the storage id's tenant list. Each remaining tenant then
  gets its own plan for the rest of the query, since its indexes can
  differ from another's (the application migrates a tenant when it opens
  it, so one not opened since a deploy may lack a new index). Grouping,
  ordering, the limit and the projection run once over all the tenants'
  rows; see `Efsql.Planner.split/1`.

  The plan's access node is `{:fan_out, [{tenant_name, plan}]}`, which
  `Efsql.Executor` reads in one FoundationDB transaction across the
  tenants, so the result is a single consistent snapshot.
  """

  alias Efsql.Exception.Unsupported
  alias Efsql.Executor
  alias Efsql.Logical
  alias Efsql.Physical.Plan
  alias Efsql.Planner

  @default_max_tenants 100

  @doc """
  Returns `{plan, tenants}`, opening tenants through the session's
  `tenants` cache (see `Efsql.open_tenant/3`).

  Options: `:max_tenants`, the most tenants one query may read (default
  #{@default_max_tenants}, or the `:efsql, :max_tenants` application
  setting). The rest are passed to the adapter as for any query.
  """
  def plan(%Logical.Select{prefix: {:all_tenants, storage_id}} = logical, tenants, options) do
    default = Application.get_env(:efsql, :max_tenants, @default_max_tenants)
    {max_tenants, options} = Keyword.pop(options, :max_tenants, default)

    {tenant_preds, row_preds} =
      Enum.split_with(logical.predicates, &(Logical.predicate_field(&1) == :_tenant))

    names =
      storage_id
      |> list_tenants()
      |> Enum.filter(&Executor.matches?(%{_tenant: &1}, tenant_preds))
      |> Enum.sort()

    if length(names) > max_tenants do
      raise Unsupported,
            "the query would read #{length(names)} tenants, more than the limit of " <>
              "#{max_tenants}; narrow it with a condition on _tenant " <>
              "(where _tenant like 'acme%')"
    end

    {rows, ops} = Planner.split(%Logical.Select{logical | predicates: row_preds})

    {per_tenant, tenants} =
      Enum.map_reduce(names, tenants, fn name, tenants ->
        {tenant, tenants} = Efsql.open_tenant(tenants, name, storage_id)
        {{name, Planner.plan(%Logical.Select{rows | tenant: tenant}, options)}, tenants}
      end)

    plan = %Plan{
      access: {:fan_out, per_tenant},
      ops: ops,
      columns: Planner.columns(logical.projection)
    }

    {plan, tenants}
  end

  defp list_tenants(nil), do: EctoFoundationDB.Tenant.list(Efsql.Repo)
  defp list_tenants(storage_id), do: Efsql.Discover.tenants(storage_id)
end
