defmodule Efsql.Executor do
  @moduledoc """
  Executes an `Efsql.Physical.Plan`: pulls rows from the plan's access node,
  then folds the operator pipeline over them.

  SQL NULL semantics: a comparison, LIKE, or IN against a NULL (nil) field is
  false — including NOT LIKE. Sorting places NULLs last ascending and first
  descending, matching PostgreSQL's defaults.
  """

  alias Efsql.Physical.Plan

  @cmp_ops ~w[== > >= < <=]a

  def run(%Plan{access: access, ops: ops}) do
    Enum.reduce(ops, fetch(access), &apply_op/2)
  end

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

  defp fetch({:union, nodes}) do
    nodes
    |> Enum.map(&async_fetch/1)
    |> Efsql.Repo.await()
    |> List.flatten()
  end

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
      value -> apply(Kernel, op, [value, param])
    end
  end

  defp eval({:range, field, {lower_op, lower}, {upper_op, upper}}, row) do
    eval({:cmp, lower_op, field, lower}, row) and eval({:cmp, upper_op, field, upper}, row)
  end

  defp eval({:in, field, values}, row) do
    case Map.get(row, field) do
      nil -> false
      value -> value in values
    end
  end

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
      {v, v} -> compare(a, b, rest)
      {nil, _} -> if dir == :asc, do: :gt, else: :lt
      {_, nil} -> if dir == :asc, do: :lt, else: :gt
      {va, vb} -> order(if(va < vb, do: :lt, else: :gt), dir)
    end
  end

  defp order(cmp, :asc), do: cmp
  defp order(:lt, :desc), do: :gt
  defp order(:gt, :desc), do: :lt
end
