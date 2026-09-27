defmodule Efsql.Aggregate do
  @moduledoc """
  `GROUP BY` and aggregates, for the `{:aggregate, group_by, aggregates}`
  operator. It runs over rows as they arrive (`new/2`, `add/2`,
  `finish/1`), keeping one small running total per group rather than the
  rows themselves, so a query across many tenants can aggregate each batch
  as it is read.

  Rows are grouped by the values of the `group_by` fields; equal values
  group together even when their terms differ (`Decimal` 1.0 and 1.00, or
  datetimes stored at different precisions), and NULLs form one group, as
  in SQL. Each group becomes one row holding its group fields and one
  column per aggregate. With no group fields, every row is one group, so
  an empty input still gives one row (`count(*)` of nothing is 0).

  SQL semantics: `count(*)` counts rows, every other aggregate skips NULLs,
  and `sum`, `min`, `max` and `avg` of no values are NULL. `sum` and `avg`
  take numbers and `Decimal`s, and become `Decimal` from the first
  `Decimal` on. `min` and `max` order with `Efsql.Types.compare/2`, so
  they work on strings and datetimes too. Groups come out ordered by their
  key.
  """

  alias Efsql.Exception.Unsupported
  alias Efsql.Types

  @type aggregate :: {name :: atom, :count | :sum | :min | :max | :avg, atom | :star}

  defstruct group_by: [], aggregates: [], groups: %{}

  @opaque t :: %__MODULE__{}

  @doc "All at once: `new/2`, `add/2` and `finish/1` over `rows`."
  @spec run([map], [atom], [aggregate]) :: [map]
  def run(rows, group_by, aggregates),
    do: group_by |> new(aggregates) |> add(rows) |> finish()

  @spec new([atom], [aggregate]) :: t()
  def new(group_by, aggregates), do: %__MODULE__{group_by: group_by, aggregates: aggregates}

  @doc "Adds rows to the running totals."
  @spec add(t(), [map]) :: t()
  def add(%__MODULE__{group_by: group_by, aggregates: aggregates} = state, rows) do
    groups =
      Enum.reduce(rows, state.groups, fn row, groups ->
        key = Enum.map(group_by, &Types.equality_key(Map.get(row, &1)))

        {values, accs} =
          Map.get_lazy(groups, key, fn ->
            {Map.new(group_by, &{&1, Map.get(row, &1)}), Enum.map(aggregates, &initial/1)}
          end)

        accs = Enum.zip_with(aggregates, accs, &accumulate(&1, &2, row))
        Map.put(groups, key, {values, accs})
      end)

    %__MODULE__{state | groups: groups}
  end

  @doc "One row per group, ordered by the group fields."
  @spec finish(t()) :: [map]
  def finish(%__MODULE__{group_by: group_by, aggregates: aggregates, groups: groups}) do
    # A whole-table aggregate answers even when no row matched.
    groups =
      if group_by == [] and groups == %{},
        do: [{%{}, Enum.map(aggregates, &initial/1)}],
        else: Map.values(groups)

    groups
    |> Enum.map(fn {values, accs} ->
      aggregates
      |> Enum.zip(accs)
      |> Enum.reduce(values, fn {{name, function, _arg}, acc}, row ->
        Map.put(row, name, result(function, acc))
      end)
    end)
    |> Efsql.Executor.sort(Enum.map(group_by, &{:asc, &1}))
  end

  # -- running totals --

  defp initial({_name, :count, _arg}), do: 0
  defp initial({_name, :avg, _arg}), do: {nil, 0}
  defp initial({_name, _function, _arg}), do: nil

  defp accumulate({_name, :count, :star}, n, _row), do: n + 1

  defp accumulate({_name, function, field}, acc, row) do
    case Map.get(row, field) do
      nil -> acc
      value -> step(function, field, acc, value)
    end
  end

  defp step(:count, _field, n, _value), do: n + 1
  defp step(:sum, field, total, value), do: add_number(total, value, field)
  defp step(:avg, field, {total, n}, value), do: {add_number(total, value, field), n + 1}
  defp step(:min, _field, best, value), do: better(best, value, :lt)
  defp step(:max, _field, best, value), do: better(best, value, :gt)

  defp better(nil, value, _keep), do: value

  defp better(best, value, keep),
    do: if(Types.compare(value, best) == keep, do: value, else: best)

  defp add_number(total, value, field) do
    unless is_number(value) or is_struct(value, Decimal) do
      raise Unsupported,
            "sum and avg need numbers, but #{field} holds #{inspect(value, limit: 5)}"
    end

    cond do
      total == nil ->
        value

      is_struct(total, Decimal) or is_struct(value, Decimal) ->
        Decimal.add(decimal(total), decimal(value))

      true ->
        total + value
    end
  end

  defp result(:avg, {nil, 0}), do: nil
  defp result(:avg, {%Decimal{} = total, n}), do: Decimal.div(total, n)
  defp result(:avg, {total, n}), do: total / n
  defp result(_function, acc), do: acc

  defp decimal(%Decimal{} = d), do: d
  defp decimal(n) when is_integer(n), do: Decimal.new(n)
  defp decimal(n) when is_float(n), do: Decimal.from_float(n)
end
