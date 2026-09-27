defmodule Efsql.Rewrite do
  @moduledoc """
  Normalization passes over an `Efsql.Logical` query. Each pass is a pure
  `logical -> logical` function; `normalize/1` runs them in order. New
  rewrite rules (contradiction detection, ...) are added here as further
  passes. (NOT is pushed down earlier, by `Efsql.Parser`.)
  """

  alias Efsql.Logical
  alias Efsql.Predicate
  alias Efsql.Types

  @lower_ops ~w[> >=]a
  @upper_ops ~w[< <=]a

  def normalize(%Logical.Select{} = logical) do
    logical
    |> pass_merge_ranges()
    |> pass_like_prefix()
    |> pass_or_in()
    |> pass_in_singleton()
  end

  # A lower bound and an upper bound on the same field collapse into one
  # range predicate, which the adapter can answer with a single GetRange.
  def pass_merge_ranges(%Logical.Select{predicates: preds} = logical) do
    %Logical.Select{logical | predicates: merge_ranges(preds, [])}
  end

  defp merge_ranges([], acc), do: Enum.reverse(acc)

  defp merge_ranges([{:cmp, op, field, value} | rest], acc) when op in @lower_ops do
    case take_bound(rest, field, @upper_ops) do
      {nil, _} ->
        merge_ranges(rest, [{:cmp, op, field, value} | acc])

      {{:cmp, op2, _f, value2}, rest2} ->
        merge_ranges(rest2, [{:range, field, {op, value}, {op2, value2}} | acc])
    end
  end

  defp merge_ranges([{:cmp, op, field, value} | rest], acc) when op in @upper_ops do
    case take_bound(rest, field, @lower_ops) do
      {nil, _} ->
        merge_ranges(rest, [{:cmp, op, field, value} | acc])

      {{:cmp, op2, _f, value2}, rest2} ->
        merge_ranges(rest2, [{:range, field, {op2, value2}, {op, value}} | acc])
    end
  end

  defp merge_ranges([pred | rest], acc), do: merge_ranges(rest, [pred | acc])

  defp take_bound(preds, field, ops) do
    Predicate.take_first(preds, fn
      {:cmp, op, f, _v} -> op in ops and f == field
      _ -> false
    end)
  end

  # `field like 'prefix%'` is exactly a key range. A pattern with a wildcard
  # mid-string still narrows to its literal prefix range, but keeps the full
  # pattern as a residual filter.
  def pass_like_prefix(%Logical.Select{predicates: preds} = logical) do
    %Logical.Select{logical | predicates: Enum.flat_map(preds, &rewrite_like/1)}
  end

  defp rewrite_like({:like, field, pattern} = pred) do
    case split_prefix(pattern) do
      :no_prefix -> [pred]
      {:exact, prefix} -> [prefix_range(field, prefix)]
      {:prefix, prefix} -> [prefix_range(field, prefix), pred]
    end
  end

  defp rewrite_like(other), do: [other]

  defp split_prefix(pattern) do
    prefix =
      pattern
      |> String.graphemes()
      |> Enum.take_while(&(&1 not in ["%", "_"]))
      |> Enum.join()

    cond do
      prefix == "" -> :no_prefix
      pattern == prefix <> "%" -> {:exact, prefix}
      true -> {:prefix, prefix}
    end
  end

  defp prefix_range(field, prefix) do
    case strinc(prefix) do
      nil -> {:cmp, :>=, field, prefix}
      upper -> {:range, field, {:>=, prefix}, {:<, upper}}
    end
  end

  # First binary strictly greater than every binary with this prefix
  # (drop trailing 0xFF bytes, then increment the last byte).
  defp strinc(bin) do
    case trim_ff(bin) do
      "" ->
        nil

      trimmed ->
        head_size = byte_size(trimmed) - 1
        <<head::binary-size(head_size), last>> = trimmed
        head <> <<last + 1>>
    end
  end

  defp trim_ff(bin) do
    case bin do
      "" ->
        ""

      _ ->
        head_size = byte_size(bin) - 1

        case bin do
          <<head::binary-size(head_size), 0xFF>> -> trim_ff(head)
          _ -> bin
        end
    end
  end

  # `a = 1 OR a = 2 OR a IN (3, 4)` is `a IN (1, 2, 3, 4)`, which an index
  # or the primary key serves as one lookup per value; any other OR is
  # only checked on the rows read.
  def pass_or_in(%Logical.Select{predicates: preds} = logical) do
    %Logical.Select{logical | predicates: Enum.map(preds, &or_in/1)}
  end

  defp or_in({:or, branches} = pred) do
    values = Enum.map(branches, &in_values/1)

    case Enum.uniq_by(values, &elem(&1, 0)) do
      [{field, _}] when field != nil -> {:in, field, Enum.flat_map(values, &elem(&1, 1))}
      _ -> pred
    end
  end

  defp or_in(pred), do: pred

  defp in_values([{:cmp, :==, field, value}]), do: {field, [value]}
  defp in_values([{:in, field, values}]), do: {field, values}
  defp in_values(_branch), do: {nil, []}

  # An IN list holds each value once, since each is read on its own (`a IN
  # (1, 1)` would read a = 1 twice). Then `field in (v)` is an equality,
  # and `field not in (v)` an inequality.
  def pass_in_singleton(%Logical.Select{predicates: preds} = logical) do
    predicates =
      Enum.map(preds, fn
        {kind, field, values} when kind in [:in, :not_in] ->
          case {kind, Enum.uniq_by(values, &Types.equality_key/1)} do
            {:in, [value]} -> {:cmp, :==, field, value}
            {:not_in, [value]} -> {:cmp, :!=, field, value}
            {kind, values} -> {kind, field, values}
          end

        pred ->
          pred
      end)

    %Logical.Select{logical | predicates: predicates}
  end
end
