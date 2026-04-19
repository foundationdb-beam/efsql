defmodule Efsql.QuerySplitter do
  alias Efsql.Exception.Unsupported

  # Partition full scan: _ = ('partition', *)
  def partition(
        query = %Ecto.Query{
          wheres: [
            %Ecto.Query.BooleanExpr{
              op: :and,
              expr: {:==, [], [{{:., [], [{:&, [], [0]}, :_]}, [], []}, {part, :*}]}
            }
          ]
        },
        options
      ) do
    id_a = {part, EctoFoundationDB.Versionstamp.min()}
    id_b = {part, EctoFoundationDB.Versionstamp.max()}
    query1 = %Ecto.Query{query | wheres: []}
    options = Keyword.merge(options, inclusive_left?: true, inclusive_right?: true)
    {:all_range, {query1, id_a, id_b, options}, query1}
  end

  # pk Equal
  def partition(
        query = %Ecto.Query{
          wheres: [
            %Ecto.Query.BooleanExpr{
              op: :and,
              expr: {:==, [], [{{:., [], [{:&, [], [0]}, :_]}, [], []}, id]}
            }
            | rest
          ]
        },
        options
      ) do
    query1 = %Ecto.Query{query | wheres: []}
    query2 = %Ecto.Query{query | wheres: rest}

    if length(rest) > 0 do
      raise Unsupported, """
      Query must be minimally constrained
      """
    end

    options = Keyword.merge(options, inclusive_left?: true, inclusive_right?: true)

    {:all_range, {query1, id, id, options}, query2}
  end

  # pk Between
  def partition(
        query = %Ecto.Query{
          wheres: [
            %Ecto.Query.BooleanExpr{
              op: :and,
              expr:
                {{lhs, [], [{{:., [], [{:&, [], [0]}, :_]}, [], []}, id_a]},
                 {rhs, [], [{{:., [], [{:&, [], [0]}, :_]}, [], []}, id_b]}}
            }
            | rest
          ]
        },
        options
      )
      when lhs in ~w[> >=]a and rhs in ~w[< <=]a do
    query1 = %Ecto.Query{query | wheres: []}
    query2 = %Ecto.Query{query | wheres: rest}

    if length(rest) > 0 do
      raise Unsupported, """
      Query must be minimally constrained
      """
    end

    options1 = []
    options1 = if lhs == :>, do: options1 ++ [inclusive_left?: false], else: options1
    options1 = if rhs == :<=, do: options1 ++ [inclusive_right?: true], else: options1
    options = Keyword.merge(options, options1)

    {:all_range, {query1, id_a, id_b, options}, query2}
  end

  def partition(
        query = %Ecto.Query{
          wheres: [
            %Ecto.Query.BooleanExpr{
              op: :and,
              expr: {op, [], [{{:., [], [{:&, [], [0]}, :_]}, [], []}, id]}
            }
            | rest
          ]
        },
        options
      )
      when op in ~w[> >= < <=]a do
    query1 = %Ecto.Query{query | wheres: []}
    query2 = %Ecto.Query{query | wheres: rest}

    if length(rest) > 0 do
      raise Unsupported, """
      Query must be minimally constrained
      """
    end

    options1 = []
    options1 = if op == :>, do: options1 ++ [inclusive_left?: false], else: options1
    options1 = if op == :<=, do: options1 ++ [inclusive_right?: true], else: options1
    options = Keyword.merge(options, options1)

    id_s = if op in ~w[> >=]a, do: id
    id_e = if op in ~w[< <=]a, do: id

    {:all_range, {query1, id_s, id_e, options}, query2}
  end

  # full table scan (no WHERE) — use all_range with open bounds
  def partition(query = %Ecto.Query{wheres: []}, options) do
    {:all_range, {query, nil, nil, options}, query}
  end

  # index queries and anything else
  def partition(query, options) do
    {:all, {query, options}, query}
  end
end
