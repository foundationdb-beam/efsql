defmodule Efsql.Rewrite do
  @moduledoc """
  Normalization passes over an `Efsql.Logical` query. Each pass is a pure
  `logical -> logical` function; `normalize/1` runs them in order. New
  rewrite rules (OR to DNF, NOT pushdown, contradiction detection, ...) are
  added here as further passes.
  """

  alias Efsql.Logical

  @lower_ops ~w[> >=]a
  @upper_ops ~w[< <=]a

  def normalize(%Logical.Select{} = logical) do
    logical
    |> pass_merge_ranges()
    |> pass_like_prefix()
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
      nil -> merge_ranges(rest, [{:cmp, op, field, value} | acc])
      {{:cmp, op2, _f, value2}, rest2} -> merge_ranges(rest2, [{:range, field, {op, value}, {op2, value2}} | acc])
    end
  end

  defp merge_ranges([{:cmp, op, field, value} | rest], acc) when op in @upper_ops do
    case take_bound(rest, field, @lower_ops) do
      nil -> merge_ranges(rest, [{:cmp, op, field, value} | acc])
      {{:cmp, op2, _f, value2}, rest2} -> merge_ranges(rest2, [{:range, field, {op2, value2}, {op, value}} | acc])
    end
  end

  defp merge_ranges([pred | rest], acc), do: merge_ranges(rest, [pred | acc])

  defp take_bound(preds, field, ops) do
    match? = fn
      {:cmp, op, f, _v} -> op in ops and f == field
      _ -> false
    end

    case Enum.split_while(preds, &(not match?.(&1))) do
      {_before, []} -> nil
      {before, [match | rest]} -> {match, before ++ rest}
    end
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

  # `field in (v)` is an equality.
  def pass_in_singleton(%Logical.Select{predicates: preds} = logical) do
    predicates =
      Enum.map(preds, fn
        {:in, field, [value]} -> {:cmp, :==, field, value}
        pred -> pred
      end)

    %Logical.Select{logical | predicates: predicates}
  end
end
