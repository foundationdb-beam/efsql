defmodule Efsql.Predicate do
  @moduledoc """
  A condition from a `WHERE` clause, and everything it means: which field
  it's on, whether a row satisfies it, how the planner can serve it, and
  the Ecto expression that pushes it to the adapter. A query's predicates
  are an implicitly AND-ed list of:

    * `{:cmp, op, field, value}` — op in `:== :> :>= :< :<=`
    * `{:range, field, {lower_op, value}, {upper_op, value}}` — a two-sided
      bound, `lower_op` in `:> :>=`, `upper_op` in `:< :<=`
    * `{:like, field, pattern}` / `{:not_like, field, pattern}`
    * `{:in, field, values}`
    * `{:is_null, field}` / `{:not_null, field}`

  The primary key is the pseudo-field `:_`.

  A new kind of predicate is added here, clause by clause, plus its
  translation in `Efsql.Parser` and any rewrite in `Efsql.Rewrite`.
  """

  alias Efsql.Exception.Unsupported
  alias Efsql.Types

  @type field :: atom()
  @type t ::
          {:cmp, :== | :> | :>= | :< | :<=, field(), term()}
          | {:range, field(), {:> | :>=, term()}, {:< | :<=, term()}}
          | {:like | :not_like, field(), String.t()}
          | {:in, field(), [term()]}
          | {:is_null | :not_null, field()}

  @pk_field :_

  @cmp_results %{
    ==: [:eq],
    >: [:gt],
    >=: [:gt, :eq],
    <: [:lt],
    <=: [:lt, :eq]
  }

  @doc "The field a predicate constrains."
  @spec field(t()) :: field()
  def field({:cmp, _op, field, _value}), do: field
  def field({:range, field, _lower, _upper}), do: field
  def field({:like, field, _pattern}), do: field
  def field({:not_like, field, _pattern}), do: field
  def field({:in, field, _values}), do: field
  def field({:is_null, field}), do: field
  def field({:not_null, field}), do: field

  # -- evaluation --

  @doc """
  Whether `row` satisfies every one of `predicates`, with SQL NULL
  semantics: a NULL (nil or absent) field matches no comparison, LIKE or
  IN, NOT LIKE included, and IS NULL matches it. Values compare with
  `Efsql.Types.compare/2`.
  """
  @spec matches?(map(), [t()]) :: boolean()
  def matches?(row, predicates), do: Enum.all?(predicates, &eval(&1, row))

  defp eval({:cmp, op, field, param}, row),
    do: on_value(row, field, &(Types.compare(&1, param) in Map.fetch!(@cmp_results, op)))

  defp eval({:range, field, {lower_op, lower}, {upper_op, upper}}, row),
    do: eval({:cmp, lower_op, field, lower}, row) and eval({:cmp, upper_op, field, upper}, row)

  defp eval({:in, field, values}, row),
    do:
      on_value(row, field, fn value -> Enum.any?(values, &(Types.compare(value, &1) == :eq)) end)

  defp eval({:is_null, field}, row), do: Map.get(row, field) == nil
  defp eval({:not_null, field}, row), do: Map.get(row, field) != nil

  defp eval({:like, field, pattern}, row),
    do: on_value(row, field, &Regex.match?(like_regex(pattern), &1))

  defp eval({:not_like, field, pattern}, row),
    do: on_value(row, field, &(not Regex.match?(like_regex(pattern), &1)))

  defp on_value(row, field, fun) do
    case Map.get(row, field) do
      nil -> false
      value -> fun.(value)
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

  # -- planning --

  @doc """
  How the planner can serve a predicate:

    * `:key` - a constraint on the primary key, read as a key range
    * `:in` - an `IN` list, read as one lookup per value when an index or
      the key can serve them
    * `:index` - an equality or range an index may serve
    * `:filter` - only checked on the rows read
  """
  @spec pushdown(t()) :: :key | :in | :index | :filter
  def pushdown({:in, _field, _values}), do: :in
  def pushdown({:cmp, _op, @pk_field, _value}), do: :key
  def pushdown({:range, @pk_field, _lower, _upper}), do: :key
  def pushdown({:cmp, _op, _field, _value}), do: :index
  def pushdown({:range, _field, _lower, _upper}), do: :index
  def pushdown(_predicate), do: :filter

  @doc "Whether a predicate pins its field to one value."
  def equality?({:cmp, :==, _field, _value}), do: true
  def equality?(_predicate), do: false

  @doc "Whether a predicate bounds its field on one or both sides."
  def range?({:range, _field, _lower, _upper}), do: true
  def range?({:cmp, op, _field, _value}) when op in ~w[> >= < <=]a, do: true
  def range?(_predicate), do: false

  @doc """
  Takes the first predicate `fun` accepts out of `predicates`:
  `{predicate, rest}`, or `{nil, predicates}` when none does.
  """
  def take_first(predicates, fun) do
    case Enum.split_while(predicates, &(not fun.(&1))) do
      {_before, []} -> {nil, predicates}
      {before, [match | rest]} -> {match, before ++ rest}
    end
  end

  # -- pushdown --

  @doc """
  The Ecto `where` expression that pushes an `:index` predicate to the
  adapter, its values encoded as the adapter's indexes store them (see
  `Efsql.Types.index_key/1`).
  """
  def to_ecto({:cmp, op, field, value}),
    do: {op, [], [field_ref(field), Types.index_key(value)]}

  def to_ecto({:range, field, {lower_op, lower}, {upper_op, upper}}) do
    {{lower_op, [], [field_ref(field), Types.index_key(lower)]},
     {upper_op, [], [field_ref(field), Types.index_key(upper)]}}
  end

  def to_ecto(predicate),
    do: raise(Unsupported, "predicate #{inspect(predicate)} cannot be pushed to the adapter")

  @doc "An Ecto reference to a field of the query's (only) source."
  def field_ref(field), do: {{:., [], [{:&, [], [0]}, field]}, [], []}
end
