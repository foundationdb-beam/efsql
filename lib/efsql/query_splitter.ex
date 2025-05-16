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
        }
      ) do
    query1 = %Ecto.Query{query | wheres: []}
    query2 = %Ecto.Query{query | wheres: rest}

    if length(rest) > 0 do
      raise Unsupported, """
      Query must be minimally constrained
      """
    end

    {:all_range, {query1, id, id, [inclusive_left?: true, inclusive_right?: true]}, query2}
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
        }
      )
      when lhs in ~w[> >=]a and rhs in ~w[< <=]a do
    query1 = %Ecto.Query{query | wheres: []}
    query2 = %Ecto.Query{query | wheres: rest}

    if length(rest) > 0 do
      raise Unsupported, """
      Query must be minimally constrained
      """
    end

    options = []
    options = if lhs == :>, do: options ++ [inclusive_left?: false], else: options
    options = if rhs == :<=, do: options ++ [inclusive_right?: true], else: options

    {:all_range, {query1, id_a, id_b, options}, query2}
  end

  # all others
  def partition(query) do
    {:all, query, query}
  end
end
