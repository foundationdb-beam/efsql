defmodule Efsql.QuerySplitter do
  alias Efsql.Exception.Unsupported

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

  # all others
  def partition(query, options) do
    {:all, {query, options}, query}
  end
end
