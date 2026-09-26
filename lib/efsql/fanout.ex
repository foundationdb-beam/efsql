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

  One transaction has to finish within FoundationDB's five seconds, so a
  query over many or large tenants may not fit. With `:tenant_batch` set,
  the tenants are read in batches of that many, one transaction each:
  `{:batches, [{:fan_out, ...}], concurrency}`. Up to `concurrency`
  batches are read at once, each in a process and transaction of its own.
  Each batch is a snapshot of its own, so the result as a whole is not
  one; `transactions/1` says how many there were, for the result to say
  so. Grouping, ordering and the limit still apply to all the rows
  together.
  """

  alias Efsql.Exception.Unsupported
  alias Efsql.Executor
  alias Efsql.Logical
  alias Efsql.Physical.Plan
  alias Efsql.Planner

  @default_max_tenants 100
  @default_batch_concurrency 4

  @doc """
  Returns `{plan, tenants}`, opening tenants through the session's
  `tenants` cache (see `Efsql.open_tenant/3`).

  Options:

    * `:tenant_batch` - read the tenants in batches of this many, one
      transaction each, instead of all in one. Default nil (one).
    * `:batch_concurrency` - how many batches to read at once (default
      #{@default_batch_concurrency}, or the `:efsql, :batch_concurrency`
      application setting).
    * `:max_tenants` - the most tenants one transaction may read (default
      #{@default_max_tenants}, or the `:efsql, :max_tenants` application
      setting). It doesn't apply with `:tenant_batch`, which bounds each
      transaction itself.

  The rest are passed to the adapter as for any query.
  """
  def plan(%Logical.Select{prefix: {:all_tenants, storage_id}} = logical, tenants, options) do
    default = Application.get_env(:efsql, :max_tenants, @default_max_tenants)
    {max_tenants, options} = Keyword.pop(options, :max_tenants, default)
    {batch, options} = Keyword.pop(options, :tenant_batch)

    concurrency_default =
      Application.get_env(:efsql, :batch_concurrency, @default_batch_concurrency)

    {concurrency, options} = Keyword.pop(options, :batch_concurrency, concurrency_default)

    for {name, value} <- [tenant_batch: batch, batch_concurrency: concurrency],
        value != nil and not (is_integer(value) and value > 0) do
      raise ArgumentError, "#{name} must be a positive integer, got #{inspect(value)}"
    end

    {tenant_preds, row_preds} =
      Enum.split_with(logical.predicates, &(Logical.predicate_field(&1) == :_tenant))

    names =
      storage_id
      |> list_tenants()
      |> Enum.filter(&Executor.matches?(%{_tenant: &1}, tenant_preds))
      |> Enum.sort()

    if batch == nil and length(names) > max_tenants do
      raise Unsupported,
            "the query would read #{length(names)} tenants, more than the limit of " <>
              "#{max_tenants} in one transaction; narrow it with a condition on _tenant " <>
              "(where _tenant like 'acme%'), or read them in batches " <>
              "(\\set tenant_batch 25), giving up the single snapshot"
    end

    {rows, ops} = Planner.split(%Logical.Select{logical | predicates: row_preds})

    {per_tenant, tenants} =
      Enum.map_reduce(names, tenants, fn name, tenants ->
        {tenant, tenants} = Efsql.open_tenant(tenants, name, storage_id)
        {{name, Planner.plan(%Logical.Select{rows | tenant: tenant}, options)}, tenants}
      end)

    access =
      if batch,
        do:
          {:batches, per_tenant |> Enum.chunk_every(batch) |> Enum.map(&{:fan_out, &1}),
           concurrency},
        else: {:fan_out, per_tenant}

    plan = %Plan{
      access: access,
      ops: ops,
      columns: Planner.columns(logical.projection)
    }

    {plan, tenants}
  end

  @doc """
  How many transactions, so snapshots, a plan's result comes from: more
  than one only for a query across tenants read in batches.
  """
  def transactions(%Plan{access: {:batches, batches, _concurrency}}), do: length(batches)
  def transactions(%Plan{}), do: 1

  defp list_tenants(nil), do: EctoFoundationDB.Tenant.list(Efsql.Repo)
  defp list_tenants(storage_id), do: Efsql.Discover.tenants(storage_id)
end
