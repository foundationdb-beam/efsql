defmodule Efsql.Parser do
  @moduledoc """
  SQL text to `Efsql.Logical.Select`: parses with `Efsql.SQL.Parser`, then
  translates the syntax tree. Syntax problems raise `Efsql.SQL.SyntaxError`;
  valid SQL that efsql can't execute (`OR`, comparing two columns, ...)
  raises `Efsql.Exception.Unsupported`.

  Purely a translation — normalization (range merging, LIKE rewriting)
  happens in `Efsql.Rewrite`.
  """

  alias Efsql.Exception.Unsupported
  alias Efsql.Logical
  alias Efsql.SQL.AST
  alias Efsql.Types

  @flipped %{:< => :>, :> => :<, :<= => :>=, :>= => :<=, := => :=}
  @max_versionstamp Bitwise.bsl(1, 96) - 1

  def sql_to_logical(sql) do
    sql |> Efsql.SQL.Parser.parse!() |> to_logical()
  end

  def to_logical(%AST.Select{} = select) do
    {prefix, source} = split_from(select.from)

    %Logical.Select{
      projection: projection(select.fields),
      source: source,
      prefix: prefix,
      predicates: predicates(select.where),
      order: Enum.map(select.order_by, fn {name, dir} -> {dir, field(name)} end),
      limit: select.limit
    }
  end

  defp projection(:star), do: :star
  defp projection(fields), do: Enum.map(fields, &field/1)

  defp split_from([table]), do: {nil, table}
  defp split_from([tenant, table]), do: {tenant, table}
  defp split_from([storage, tenant, table]), do: {{storage, tenant}, table}

  # -- WHERE --

  defp predicates(nil), do: []
  defp predicates(expr), do: expr |> conjuncts([]) |> Enum.map(&predicate/1)

  defp conjuncts({:and, left, right}, acc), do: conjuncts(left, conjuncts(right, acc))
  defp conjuncts(expr, acc), do: [expr | acc]

  defp predicate({:compare, :<>, _left, _right}),
    do: raise(Unsupported, "<> and != are not supported")

  defp predicate({:compare, op, {:column, _} = column, {:column, _}}),
    do:
      raise(Unsupported, "comparing two fields (#{describe(column)} #{op} ...) is not supported")

  defp predicate({:compare, op, {:column, field}, value}),
    do: {:cmp, logical_op(op), field(field), value(value)}

  # `1 < x` reads as `x > 1`
  defp predicate({:compare, op, value, {:column, field}}),
    do: {:cmp, logical_op(Map.fetch!(@flipped, op)), field(field), value(value)}

  defp predicate({:between, {:column, field}, low, high, false}),
    do: {:range, field(field), {:>=, value(low)}, {:<=, value(high)}}

  defp predicate({:in, {:column, field}, values, false}),
    do: {:in, field(field), Enum.map(values, &value/1)}

  defp predicate({:like, {:column, field}, pattern, negated?}) do
    pattern =
      case value(pattern) do
        pattern when is_binary(pattern) -> pattern
        other -> raise Unsupported, "a LIKE pattern must be a string, got #{inspect(other)}"
      end

    {if(negated?, do: :not_like, else: :like), field(field), pattern}
  end

  defp predicate({:is_null, {:column, "_"}, _negated?}),
    do: raise(Unsupported, "the primary key '_' is never NULL")

  defp predicate({:is_null, {:column, field}, negated?}),
    do: {if(negated?, do: :not_null, else: :is_null), field(field)}

  defp predicate({:or, _, _}), do: raise(Unsupported, "OR is not supported")
  defp predicate({:not, _}), do: raise(Unsupported, "NOT is not supported")

  defp predicate({:between, _, _, _, true}),
    do: raise(Unsupported, "NOT BETWEEN is not supported")

  defp predicate({:in, _, _, true}), do: raise(Unsupported, "NOT IN is not supported")
  defp predicate({:ilike, _, _, _}), do: raise(Unsupported, "ILIKE is not supported")

  defp predicate({kind, _, _, _}) when kind in [:in, :like],
    do: raise(Unsupported, "#{String.upcase(to_string(kind))} needs a field on its left")

  defp predicate({:between, _, _, _, _}),
    do: raise(Unsupported, "BETWEEN needs a field on its left")

  defp predicate({:is_null, _, _}), do: raise(Unsupported, "IS NULL needs a field on its left")

  defp predicate({:compare, _op, _left, _right}),
    do: raise(Unsupported, "a comparison needs a field on one side")

  defp predicate(expr),
    do: raise(Unsupported, "#{describe(expr)} is not a condition; compare it to something")

  defp logical_op(:=), do: :==
  defp logical_op(op), do: op

  # Fields are atoms, which can't be longer than 255 characters.
  defp field(name) do
    if String.length(name) > 255 do
      raise Unsupported, "field names are limited to 255 characters"
    end

    String.to_atom(name)
  end

  # -- values --

  # SQL's `x = null` is never true, which is never what was meant.
  defp value({:literal, nil}),
    do: raise(Unsupported, "a comparison with NULL is never true; use IS NULL or IS NOT NULL")

  defp value({:literal, value}), do: value
  defp value({:cast, expr, type}), do: Types.cast(type, value(expr))

  # Versionstamp primary keys partitioned by a field: ('partition', *) is
  # the whole partition, ('partition', n) one versionstamp in it.
  defp value({:tuple, [{:literal, part}, :star]}) when is_binary(part), do: {part, :*}

  defp value({:tuple, [{:literal, part}, {:literal, n}]})
       when is_binary(part) and is_integer(n) and n >= 0 and n <= @max_versionstamp,
       do: {part, EctoFoundationDB.Versionstamp.from_integer(n)}

  defp value({:tuple, [{:literal, part}, {:literal, n}]}) when is_binary(part) and is_integer(n),
    do: raise(Unsupported, "a versionstamp is a whole number from 0 to 2^96 - 1, got #{n}")

  defp value({:tuple, _}),
    do: raise(Unsupported, "a tuple must be ('partition', *) or ('partition', versionstamp)")

  defp value({:column, _} = column),
    do: raise(Unsupported, "expected a value, got #{describe(column)}")

  defp value(expr), do: raise(Unsupported, "expected a value, got #{describe(expr)}")

  defp describe({:column, name}), do: "the field #{name}"
  defp describe({:literal, value}), do: inspect(value)
  defp describe({:cast, _, type}), do: "a #{type} value"
  defp describe({kind, _, _}) when kind in [:and, :or], do: "a condition"
  defp describe(_), do: "a condition"
end
