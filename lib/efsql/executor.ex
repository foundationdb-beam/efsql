defmodule Efsql.Executor do
  @moduledoc """
  Executes an `Efsql.Physical.Plan`: reads rows through the plan's access
  node and feeds them, as they arrive, through an `Efsql.Pipeline` of its
  operators. A batched read across tenants arrives a batch at a time, and
  stops early when the pipeline has all it needs (a `LIMIT` met).
  Predicates evaluate with `Efsql.Predicate`'s SQL NULL semantics, and
  `sort/2` orders NULLs as PostgreSQL does.

  A query across tenants (`{:fan_out, [{tenant_name, plan}]}`) reads every
  tenant in one FoundationDB transaction on the database: each tenant's
  reads are started, then all awaited together, so they are pipelined and
  see one snapshot. Each tenant's own operators run on its rows, which
  then get `_tenant`, before the shared operators run on them all.
  """

  alias Efsql.Exception.Unsupported
  alias Efsql.Physical.Plan
  alias Efsql.Pipeline
  alias Efsql.Types

  # transaction_too_old (retryable) and transaction_timed_out
  @too_long [1007, 1031]

  def run(%Plan{access: access, ops: ops}) do
    access
    |> chunks()
    |> Enum.reduce_while(Pipeline.new(ops), &Pipeline.feed(&2, &1))
    |> Pipeline.finish()
  end

  @doc """
  A stream of `fun` over `items`, up to `max` at a time, each in a process
  of its own, the results in order. Halting the stream stops the work not
  yet done. A failure is raised (or thrown, or exited) in the consumer as
  it was in its process, so a caller's `rescue` sees the original
  exception rather than a linked process's exit. With `max` 1 it all runs
  in the consuming process, one item at a time.
  """
  def stream_concurrently(items, 1, fun), do: Stream.map(items, fun)

  def stream_concurrently(items, max, fun) do
    items
    |> Task.async_stream(
      fn item ->
        try do
          {:ok, fun.(item)}
        catch
          kind, reason -> {:failed, kind, reason, __STACKTRACE__}
        end
      end,
      max_concurrency: max,
      ordered: true,
      timeout: :infinity
    )
    |> Stream.map(fn
      {:ok, {:ok, result}} -> result
      {:ok, {:failed, kind, reason, stacktrace}} -> :erlang.raise(kind, reason, stacktrace)
    end)
  end

  # -- access nodes --

  # The rows a plan reads, as the chunks they arrive in: one per batch, a
  # transaction each, up to `concurrency` at a time, or else just one. A
  # pipeline that halts stops the batches not yet read.
  defp chunks({:batches, batches, concurrency}),
    do: stream_concurrently(batches, concurrency, &fetch/1)

  defp chunks(access), do: [fetch(access)]

  defp fetch({:fan_out, []}), do: []

  defp fetch({:fan_out, tenant_plans}) do
    db = Ecto.Adapters.FoundationDB.db(Efsql.Repo)
    Ecto.Adapters.FoundationDB.transactional(db, fn -> read_tenants(tenant_plans) end)
  end

  # Every other node, a union included, is one or more adapter reads:
  # start them all, then await them together, so they are pipelined.
  defp fetch(access), do: access |> start() |> Efsql.Repo.await() |> List.flatten()

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
          |> Pipeline.run(List.flatten(mine))
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
                  "or the WHERE clause, or read fewer tenants per transaction " <>
                  "(\\set tenant_batch N)"

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

  # -- sorting --

  @doc """
  Sorts rows by `[{:asc | :desc, field}]`: NULLs last ascending and first
  descending, as PostgreSQL does, and values by `Efsql.Types.compare/2`.
  """
  def sort(rows, order), do: Enum.sort(rows, fn a, b -> compare(a, b, order) != :gt end)

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
