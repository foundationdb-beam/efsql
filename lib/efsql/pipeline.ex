defmodule Efsql.Pipeline do
  @moduledoc """
  Runs a plan's operators (see `Efsql.Physical`) over rows as they arrive,
  a chunk at a time: `new/1`, then `feed/2` for each chunk, then
  `finish/1` for the result. Each operator keeps only what it has to:

    * `{:filter, predicates}` and `{:project, fields}` - nothing; rows
      pass straight through
    * `{:limit, n}` - how many rows are still wanted; once it has them,
      `feed/2` says `:halt`, and whatever feeds the pipeline can stop
      reading
    * `{:sort, order}` directly followed by `{:limit, n}` - only the best
      `n` rows so far (a running top-n), not every row
    * `{:sort, order}` alone - every row, since the last one read may sort
      first
    * `{:aggregate, group_by, aggregates}` - one running total per group
      (see `Efsql.Aggregate`)

  So a query across many tenants, read in batches, holds a limit's worth
  of rows, or a group's worth of totals, rather than every row it read,
  and a `LIMIT` without `ORDER BY` stops reading as soon as it is met.
  A single read is just one chunk.
  """

  alias Efsql.Aggregate
  alias Efsql.Executor
  alias Efsql.Predicate

  defstruct stages: [], out: []

  @opaque t :: %__MODULE__{}

  @spec new([tuple()]) :: t()
  def new(ops), do: %__MODULE__{stages: ops |> fuse() |> Enum.map(&{&1, init(&1)})}

  @doc """
  Feeds a chunk of rows through: `{:cont, pipeline}`, or `{:halt, pipeline}`
  when a limit has all its rows and no more input could change the result.
  Its shape suits `Enum.reduce_while/3`.
  """
  @spec feed(t(), [map()]) :: {:cont | :halt, t()}
  def feed(%__MODULE__{} = pipeline, rows) do
    {stages, out, halt?} = push(pipeline.stages, rows)
    pipeline = %__MODULE__{stages: stages, out: [out | pipeline.out]}
    {if(halt?, do: :halt, else: :cont), pipeline}
  end

  @doc "The result: every row the operators let through, in order."
  @spec finish(t()) :: [map()]
  def finish(%__MODULE__{} = pipeline) do
    # A stage's held rows go on through the stages after it.
    rest =
      Enum.reduce(pipeline.stages, [], fn {op, state}, pending ->
        {state, out, _halt?} = step(op, state, pending)
        out ++ flush(op, state)
      end)

    pipeline.out |> Enum.reverse() |> Enum.concat() |> Kernel.++(rest)
  end

  @doc "All at once: `new/1`, `feed/2` and `finish/1` over `rows`."
  @spec run([tuple()], [map()]) :: [map()]
  def run(ops, rows) do
    {_, pipeline} = ops |> new() |> feed(rows)
    finish(pipeline)
  end

  # A sort that a limit then cuts is a running top-n.
  defp fuse([{:sort, order}, {:limit, n} | rest]), do: [{:top, order, n} | fuse(rest)]
  defp fuse([op | rest]), do: [op | fuse(rest)]
  defp fuse([]), do: []

  defp init({:limit, n}), do: n
  defp init({:sort, _order}), do: []
  defp init({:top, _order, _n}), do: []
  defp init({:aggregate, group_by, aggregates}), do: Aggregate.new(group_by, aggregates)
  defp init(_op), do: nil

  # Each stage takes the rows the one before let through.
  defp push(stages, rows) do
    {stages, {out, halt?}} =
      Enum.map_reduce(stages, {rows, false}, fn {op, state}, {rows, halt?} ->
        {state, out, stop?} = step(op, state, rows)
        {{op, state}, {out, halt? or stop?}}
      end)

    {stages, out, halt?}
  end

  # {state, rows passed on, whether no more input is needed}
  defp step({:filter, predicates}, nil, rows),
    do: {nil, Enum.filter(rows, &Predicate.matches?(&1, predicates)), false}

  defp step({:project, fields}, nil, rows),
    do: {nil, Enum.map(rows, &Map.take(&1, fields)), false}

  defp step({:limit, _n}, remaining, rows) do
    taken = Enum.take(rows, remaining)
    remaining = remaining - length(taken)
    {remaining, taken, remaining == 0}
  end

  defp step({:sort, _order}, chunks, []), do: {chunks, [], false}
  defp step({:sort, _order}, chunks, rows), do: {[rows | chunks], [], false}

  defp step({:top, _order, _n}, best, []), do: {best, [], false}

  defp step({:top, order, n}, best, rows),
    do: {(best ++ rows) |> Executor.sort(order) |> Enum.take(n), [], false}

  defp step({:aggregate, _group_by, _aggregates}, totals, rows),
    do: {Aggregate.add(totals, rows), [], false}

  # What a stage still holds once the input is done.
  defp flush({:sort, order}, chunks),
    do: chunks |> Enum.reverse() |> Enum.concat() |> Executor.sort(order)

  defp flush({:top, _order, _n}, best), do: best
  defp flush({:aggregate, _group_by, _aggregates}, totals), do: Aggregate.finish(totals)
  defp flush(_op, _state), do: []
end
