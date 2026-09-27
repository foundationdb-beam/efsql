defmodule Efsql.Predicate do
  @moduledoc """
  A condition from a `WHERE` clause, and everything it means: which field
  it's on, whether a row satisfies it, how the planner can serve it, and
  the Ecto expression that pushes it to the adapter. A query's predicates
  are an implicitly AND-ed list of:

    * `{:cmp, op, field, value}` — op in `:== :!= :> :>= :< :<=`
    * `{:range, field, {lower_op, value}, {upper_op, value}}` — a two-sided
      bound, `lower_op` in `:> :>=`, `upper_op` in `:< :<=`; `:not_range`
      is its negation (`NOT BETWEEN`)
    * `{:like, field, pattern}` / `{:not_like, field, pattern}`, and the
      case-insensitive `:ilike` / `:not_ilike`
    * `{:in, field, values}` / `{:not_in, field, values}`
    * `{:is_null, field}` / `{:not_null, field}`
    * `{:or, branches}` — true when any branch is, each branch itself an
      AND-ed list of predicates (`a = 1 OR (b = 2 AND c = 3)` is
      `{:or, [[a = 1], [b = 2, c = 3]]}`)

  SQL's `NOT` never reaches here: `Efsql.Parser` pushes it into the
  condition it negates (`NOT (a < 1)` is `a >= 1`).

  The primary key is the pseudo-field `:_`.

  A new kind of predicate is added here, clause by clause, plus its
  translation in `Efsql.Parser` and any rewrite in `Efsql.Rewrite`.
  """

  alias Efsql.Exception.Unsupported
  alias Efsql.Types

  @type field :: atom()
  @type t ::
          {:cmp, :== | :!= | :> | :>= | :< | :<=, field(), term()}
          | {:range | :not_range, field(), {:> | :>=, term()}, {:< | :<=, term()}}
          | {:like | :not_like | :ilike | :not_ilike, field(), String.t()}
          | {:in | :not_in, field(), [term()]}
          | {:is_null | :not_null, field()}
          | {:or, [[t()]]}

  @pk_field :_

  @cmp_results %{
    ==: [:eq],
    !=: [:lt, :gt],
    >: [:gt],
    >=: [:gt, :eq],
    <: [:lt],
    <=: [:lt, :eq]
  }

  @doc "The field a predicate constrains; see `fields/1` for an OR."
  @spec field(t()) :: field()
  def field({:cmp, _op, field, _value}), do: field
  def field({kind, field, _lower, _upper}) when kind in [:range, :not_range], do: field
  def field({kind, field, _arg}) when kind in [:like, :not_like, :ilike, :not_ilike], do: field
  def field({kind, field, _values}) when kind in [:in, :not_in], do: field
  def field({kind, field}) when kind in [:is_null, :not_null], do: field

  @doc "Every field a predicate reads, in order, without duplicates."
  @spec fields(t()) :: [field()]
  def fields({:or, branches}),
    do: branches |> Enum.concat() |> Enum.flat_map(&fields/1) |> Enum.uniq()

  def fields(predicate), do: [field(predicate)]

  # -- evaluation --

  @doc """
  Whether `row` satisfies every one of `predicates`, with SQL NULL
  semantics: a NULL (nil or absent) field matches no comparison, LIKE or
  IN, negated ones included (a NULL is neither `= 1` nor `<> 1`), and
  IS NULL matches it. Values compare with
  `Efsql.Types.compare/2`.
  """
  @spec matches?(map(), [t()]) :: boolean()
  def matches?(row, predicates), do: Enum.all?(predicates, &eval(&1, row))

  defp eval({:cmp, op, field, param}, row),
    do: on_value(row, field, &(Types.compare(&1, param) in Map.fetch!(@cmp_results, op)))

  defp eval({:range, field, {lower_op, lower}, {upper_op, upper}}, row),
    do: eval({:cmp, lower_op, field, lower}, row) and eval({:cmp, upper_op, field, upper}, row)

  defp eval({:not_range, field, lower, upper}, row),
    do: on_value(row, field, fn _ -> not eval({:range, field, lower, upper}, row) end)

  defp eval({:in, field, values}, row), do: on_value(row, field, &member?(&1, values))
  defp eval({:not_in, field, values}, row), do: on_value(row, field, &(not member?(&1, values)))

  # A NULL makes a branch false, not the whole OR: `a = 1 OR b = 2` holds
  # when a is NULL and b is 2.
  defp eval({:or, branches}, row), do: Enum.any?(branches, &matches?(row, &1))

  defp eval({:is_null, field}, row), do: Map.get(row, field) == nil
  defp eval({:not_null, field}, row), do: Map.get(row, field) != nil

  defp eval({:like, field, pattern}, row),
    do: on_value(row, field, &Regex.match?(like_regex(pattern, ""), &1))

  defp eval({:not_like, field, pattern}, row),
    do: on_value(row, field, &(not Regex.match?(like_regex(pattern, ""), &1)))

  defp eval({:ilike, field, pattern}, row),
    do: on_value(row, field, &Regex.match?(like_regex(pattern, "iu"), &1))

  defp eval({:not_ilike, field, pattern}, row),
    do: on_value(row, field, &(not Regex.match?(like_regex(pattern, "iu"), &1)))

  defp member?(value, values), do: Enum.any?(values, &(Types.compare(value, &1) == :eq))

  defp on_value(row, field, fun) do
    case Map.get(row, field) do
      nil -> false
      value -> fun.(value)
    end
  end

  defp like_regex(pattern, flags) do
    source =
      pattern
      |> Regex.escape()
      |> String.replace("%", ".*")
      |> String.replace("_", ".")

    Regex.compile!("\\A" <> source <> "\\z", "s" <> flags)
  end

  # -- planning --

  @doc """
  How the planner can serve a predicate:

    * `:key` - a constraint on the primary key, read as a key range
    * `:in` - an `IN` list, read as one lookup per value when an index or
      the key can serve them
    * `:index` - an equality or range an index may serve
    * `:filter` - only checked on the rows read: LIKE, IS NULL, OR, and
      every negation (`<>`, NOT IN, NOT BETWEEN, NOT LIKE), which an index
      can't serve (an OR of equalities on one field becomes an IN first;
      see `Efsql.Rewrite`)
  """
  @spec pushdown(t()) :: :key | :in | :index | :filter
  def pushdown({:cmp, :!=, _field, _value}), do: :filter
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
