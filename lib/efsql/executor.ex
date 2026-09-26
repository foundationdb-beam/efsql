defmodule Efsql.Executor do
  @moduledoc """
  Executes an `Efsql.Physical.Plan`: pulls rows from the plan's access node,
  then folds the operator pipeline over them.

  SQL NULL semantics: a comparison, LIKE, or IN against a NULL (nil) field is
  false — including NOT LIKE. IS NULL matches a nil or absent field. Sorting places NULLs last ascending and first
  descending, matching PostgreSQL's defaults. Values compare with
  `Efsql.Types.compare/2`, so datetimes order chronologically.

  A query across tenants (`{:fan_out, [{tenant_name, plan}]}`) reads every
  tenant in one FoundationDB transaction on the database: each tenant's
  reads are started, then all awaited together, so they are pipelined and
  see one snapshot. Each tenant's own operators run on its rows, which
  then get `_tenant`, before the shared operators run on them all.
  """

  alias Efsql.Exception.Unsupported
  alias Efsql.Physical.Plan
  alias Efsql.Types

  # transaction_too_old (retryable) and transaction_timed_out
  @too_long [1007, 1031]

  @cmp_ops ~w[== > >= < <=]a
  @cmp_results %{
    ==: [:eq],
    >: [:gt],
    >=: [:gt, :eq],
    <: [:lt],
    <=: [:lt, :eq]
  }

  def run(%Plan{access: access, ops: ops}) do
    Enum.reduce(ops, fetch(access), &apply_op/2)
  end

  @doc "Whether `row` satisfies every one of `predicates`, with SQL NULL semantics."
  def matches?(row, predicates), do: Enum.all?(predicates, &eval(&1, row))

  # -- access nodes --

  defp fetch({:pk_range, query, id_start, id_end, options}) do
    Efsql.Repo.all_range(query, id_start, id_end, options)
  end

  defp fetch({:index_scan, query, options}) do
    Efsql.Repo.all(query, options)
  end

  defp fetch({:all_from_source, query, options}) do
    Efsql.Repo.all_from_source(query, options)
  end

  defp fetch({:fan_out, []}), do: []

  defp fetch({:fan_out, tenant_plans}) do
    db = Ecto.Adapters.FoundationDB.db(Efsql.Repo)
    Ecto.Adapters.FoundationDB.transactional(db, fn -> read_tenants(tenant_plans) end)
  end

  defp fetch({:union, nodes}) do
    nodes
    |> Enum.map(&async_fetch/1)
    |> Efsql.Repo.await()
    |> List.flatten()
  end

  # Runs inside the transaction. A read too big for one transaction fails
  # with transaction_too_old, which erlfdb's transactional loop would retry,
  # forever and each time as slowly. So that error is turned into one the
  # loop doesn't catch (it only retries erlfdb errors) and the query fails
  # at once; any other error still retries as usual.
  defp read_tenants(tenant_plans) do
    started =
      for {name, %Plan{access: access} = plan} <- tenant_plans,
          do: {name, plan, start(access)}

    results = started |> Enum.flat_map(&elem(&1, 2)) |> Efsql.Repo.await()

    {rows, []} =
      Enum.flat_map_reduce(started, results, fn {name, plan, futures}, results ->
        {mine, rest} = Enum.split(results, length(futures))

        rows =
          plan.ops
          |> Enum.reduce(List.flatten(mine), &apply_op/2)
          |> Enum.map(&Map.put(&1, :_tenant, name))

        {rows, rest}
      end)

    rows
  rescue
    e in ErlangError ->
      case e.original do
        {:erlfdb_error, code} when code in @too_long ->
          raise Unsupported,
                "the query read too much to finish in one transaction across " <>
                  "#{length(tenant_plans)} tenants; narrow it with a condition on _tenant " <>
                  "or the WHERE clause"

        _ ->
          reraise e, __STACKTRACE__
      end
  end

  defp start({:union, nodes}), do: Enum.map(nodes, &async_fetch/1)
  defp start(access), do: [async_fetch(access)]

  defp async_fetch({:pk_range, query, id_start, id_end, options}) do
    Efsql.Repo.async_all_range(query, id_start, id_end, options)
  end

  defp async_fetch({:index_scan, query, options}) do
    Efsql.Repo.async_all(query, options)
  end

  defp async_fetch({:all_from_source, query, options}) do
    Efsql.Repo.async_all_from_source(query, options)
  end

  # -- operators --

  defp apply_op({:filter, predicates}, rows) do
    Enum.filter(rows, fn row -> Enum.all?(predicates, &eval(&1, row)) end)
  end

  defp apply_op({:aggregate, group_by, aggregates}, rows) do
    Efsql.Aggregate.run(rows, group_by, aggregates)
  end

  defp apply_op({:sort, sort}, rows) do
    Enum.sort(rows, fn a, b -> compare(a, b, sort) != :gt end)
  end

  defp apply_op({:limit, n}, rows) do
    Enum.take(rows, n)
  end

  defp apply_op({:project, fields}, rows) do
    Enum.map(rows, &Map.take(&1, fields))
  end

  # -- predicate evaluation --

  defp eval({:cmp, op, field, param}, row) when op in @cmp_ops do
    case Map.get(row, field) do
      nil -> false
      value -> Types.compare(value, param) in Map.fetch!(@cmp_results, op)
    end
  end

  defp eval({:range, field, {lower_op, lower}, {upper_op, upper}}, row) do
    eval({:cmp, lower_op, field, lower}, row) and eval({:cmp, upper_op, field, upper}, row)
  end

  defp eval({:in, field, values}, row) do
    case Map.get(row, field) do
      nil -> false
      value -> Enum.any?(values, &(Types.compare(value, &1) == :eq))
    end
  end

  defp eval({:is_null, field}, row), do: Map.get(row, field) == nil
  defp eval({:not_null, field}, row), do: Map.get(row, field) != nil

  defp eval({:like, field, pattern}, row) do
    case Map.get(row, field) do
      nil -> false
      value -> Regex.match?(like_regex(pattern), value)
    end
  end

  defp eval({:not_like, field, pattern}, row) do
    case Map.get(row, field) do
      nil -> false
      value -> not Regex.match?(like_regex(pattern), value)
    end
  end

  defp like_regex(pattern) do
    source =
      pattern
      |> Regex.escape()
      |> String.replace("%", ".*")
      |> String.replace("_", ".")

    Regex.compile!("\\A" <> source <> "\\z", "s")
  end

  # -- sorting --

  defp compare(_a, _b, []), do: :eq

  defp compare(a, b, [{dir, field} | rest]) do
    case {Map.get(a, field), Map.get(b, field)} do
      {v, v} ->
        compare(a, b, rest)

      {nil, _} ->
        if dir == :asc, do: :gt, else: :lt

      {_, nil} ->
        if dir == :asc, do: :lt, else: :gt

      {va, vb} ->
        case Types.compare(va, vb) do
          :eq -> compare(a, b, rest)
          cmp -> order(cmp, dir)
        end
    end
  end

  defp order(cmp, :asc), do: cmp
  defp order(:lt, :desc), do: :gt
  defp order(:gt, :desc), do: :lt
end
