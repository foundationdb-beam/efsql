defmodule Efsql.Aggregate do
  @moduledoc """
  `GROUP BY` and aggregates over pulled rows, for `Efsql.Executor`'s
  `{:aggregate, group_by, aggregates}` operator.

  Rows are grouped by the values of the `group_by` fields; equal values
  group together even when their terms differ (`Decimal` 1.0 and 1.00, or
  datetimes stored at different precisions), and NULLs form one group, as
  in SQL. Each group becomes one row holding its group fields and one
  column per aggregate. With no group fields, every row is one group, so
  an empty input still gives one row (`count(*)` of nothing is 0).

  SQL semantics: `count(*)` counts rows, every other aggregate skips NULLs,
  and `sum`, `min`, `max` and `avg` of no values are NULL. `sum` and `avg`
  take numbers and `Decimal`s, and are `Decimal` when any input is.
  `min` and `max` order with `Efsql.Types.compare/2`, so they work on
  strings and datetimes too. Groups come out ordered by their key.
  """

  alias Efsql.Exception.Unsupported
  alias Efsql.Types

  @type aggregate :: {name :: atom, :count | :sum | :min | :max | :avg, atom | :star}

  @spec run([map], [atom], [aggregate]) :: [map]
  def run(rows, group_by, aggregates) do
    rows
    |> Enum.group_by(fn row -> Enum.map(group_by, &Types.equality_key(Map.get(row, &1))) end)
    |> ensure_one_group(group_by)
    |> Enum.map(fn {_key, rows} ->
      first = List.first(rows, %{})
      group = Map.new(group_by, &{&1, Map.get(first, &1)})

      Enum.reduce(aggregates, group, fn {name, function, arg}, acc ->
        Map.put(acc, name, compute(function, arg, rows))
      end)
    end)
    |> Efsql.Executor.sort(Enum.map(group_by, &{:asc, &1}))
  end

  # A whole-table aggregate answers even when no row matched.
  defp ensure_one_group(groups, []) when groups == %{}, do: [{[], []}]
  defp ensure_one_group(groups, _group_by), do: Enum.to_list(groups)

  # -- aggregates --

  defp compute(:count, :star, rows), do: length(rows)
  defp compute(:count, field, rows), do: length(values(rows, field))

  defp compute(:min, field, rows), do: extreme(values(rows, field), :lt)
  defp compute(:max, field, rows), do: extreme(values(rows, field), :gt)

  defp compute(:sum, field, rows) do
    case values(rows, field) do
      [] -> nil
      values -> sum(values, field)
    end
  end

  defp compute(:avg, field, rows) do
    case values(rows, field) do
      [] ->
        nil

      values ->
        case sum(values, field) do
          %Decimal{} = total -> Decimal.div(total, length(values))
          total -> total / length(values)
        end
    end
  end

  defp values(rows, field) do
    rows |> Enum.map(&Map.get(&1, field)) |> Enum.reject(&is_nil/1)
  end

  defp extreme([], _keep), do: nil

  defp extreme([first | rest], keep) do
    Enum.reduce(rest, first, fn value, best ->
      if Types.compare(value, best) == keep, do: value, else: best
    end)
  end

  defp sum(values, field) do
    Enum.each(values, fn value ->
      unless is_number(value) or is_struct(value, Decimal) do
        raise Unsupported,
              "sum and avg need numbers, but #{field} holds #{inspect(value, limit: 5)}"
      end
    end)

    if Enum.any?(values, &is_struct(&1, Decimal)),
      do: values |> Enum.map(&decimal/1) |> Enum.reduce(&Decimal.add/2),
      else: Enum.sum(values)
  end

  defp decimal(%Decimal{} = d), do: d
  defp decimal(n) when is_integer(n), do: Decimal.new(n)
  defp decimal(n) when is_float(n), do: Decimal.from_float(n)
end
