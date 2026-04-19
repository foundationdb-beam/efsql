defmodule Efsql.SqlToEctoQuery do
  alias Efsql.Exception.Unsupported

  @comparison_ops ~w[= >= <= > <]a

  def to_ecto_query(parsed) do
    parsed
    |> Enum.reject(fn
      {:colon, _, _} -> true
      [] -> true
      _ -> false
    end)
    |> Enum.reduce(%Ecto.Query{}, &clause_to_query/2)
  end

  defp clause_to_query({:select, _meta, fields}, %Ecto.Query{} = query) do
    case parse_select_fields(fields, []) do
      :star ->
        query

      field_names ->
        %Ecto.Query{
          query
          | select: %Ecto.Query.SelectExpr{
              expr: {:&, [], [0]},
              file: nil,
              line: nil,
              fields: nil,
              params: [],
              take: %{0 => {:any, field_names}},
              subqueries: [],
              aliases: %{}
            }
        }
    end
  end

  defp clause_to_query({:from, meta, [source_token | _]}, %Ecto.Query{} = query) do
    %Ecto.Query{
      query
      | from: %Ecto.Query.FromExpr{
          source: from_token_to_source(source_token),
          file: meta[:file],
          line: span_line(meta),
          as: nil,
          prefix: nil,
          params: [],
          hints: []
        },
        prefix: from_token_to_prefix(source_token)
    }
  end

  defp clause_to_query({:where, _meta, [expr]}, %Ecto.Query{} = query) do
    %Ecto.Query{query | wheres: parse_where_expr(expr)}
  end

  defp clause_to_query({:limit, meta, [{:numeric, _nmeta, value}]}, %Ecto.Query{} = query) do
    %Ecto.Query{
      query
      | limit: %Ecto.Query.LimitExpr{
          expr: :erlang.list_to_integer(value),
          file: meta[:file],
          line: span_line(meta),
          with_ties: false,
          params: []
        }
    }
  end

  defp clause_to_query({token, _, _}, %Ecto.Query{}) do
    raise Unsupported, "'#{token}' is not supported"
  end

  # SELECT

  defp parse_select_fields([], acc), do: Enum.reverse(acc)

  defp parse_select_fields([{:*, _, []} | _], _acc), do: :star

  defp parse_select_fields([{:comma, _meta, [field]} | rest], acc) do
    parse_select_fields(rest, [token_to_field_atom(field) | acc])
  end

  defp parse_select_fields([field | rest], acc) do
    parse_select_fields(rest, [token_to_field_atom(field) | acc])
  end

  defp token_to_field_atom({:ident, _meta, value}), do: charlist_to_atom(value)
  defp token_to_field_atom({:double_quote, _meta, value}), do: charlist_to_atom(value)
  defp token_to_field_atom({token, _meta, []}), do: token

  defp token_to_field_atom({token, _meta, args}) do
    raise Unsupported, "Expected an identifier, got #{token}/#{length(args)} instead."
  end

  # FROM

  defp from_token_to_source({:dot, _meta, [_storage, {:dot, _, [_tenant, {:ident, _m, table}]}]}) do
    {:erlang.list_to_binary(table), nil}
  end

  defp from_token_to_source({:dot, _meta, [_schema, {:ident, _m, table}]}) do
    {:erlang.list_to_binary(table), nil}
  end

  defp from_token_to_source({:ident, _meta, table}) do
    {:erlang.list_to_binary(table), nil}
  end

  defp from_token_to_prefix({:dot, _meta, [{_st, _sm, storage}, {:dot, _, [{_tt, _tm, tenant}, _table]}]}) do
    {:erlang.list_to_binary(storage), :erlang.list_to_binary(tenant)}
  end

  defp from_token_to_prefix({:dot, _meta, [{_tag, _m, schema}, _table]}) do
    :erlang.list_to_binary(schema)
  end

  defp from_token_to_prefix(_), do: nil

  # WHERE

  defp parse_where_expr({:and, meta, [lhs, rhs]}) do
    lhs_expr = parse_comparison(lhs, meta)
    rhs_expr = parse_comparison(rhs, meta)
    merge_range(lhs_expr, rhs_expr)
  end

  defp parse_where_expr({:between, meta, [field, {:and, _and_meta, [rhs1, rhs2]}]}) do
    where_field = token_to_field_atom(field)
    param1 = token_to_param(rhs1)
    param2 = token_to_param(rhs2)
    expr1 = {:>=, [], [field_ref(where_field), param1]}
    expr2 = {:<=, [], [field_ref(where_field), param2]}

    [
      %Ecto.Query.BooleanExpr{
        op: :and,
        expr: {expr1, expr2},
        file: meta[:file],
        line: span_line(meta),
        params: [],
        subqueries: []
      }
    ]
  end

  defp parse_where_expr({operator, _meta, [_lhs, _rhs]} = token)
       when operator in @comparison_ops do
    [parse_comparison(token, [])]
  end

  defp parse_where_expr({token, _meta, args}) do
    raise Unsupported, "'#{token}'/#{length(args)} is not supported in the where clause."
  end

  defp parse_comparison({operator, meta, [lhs, rhs]}, _parent_meta)
       when operator in @comparison_ops do
    where_field = token_to_field_atom(lhs)
    param = token_to_param(rhs)

    %Ecto.Query.BooleanExpr{
      op: :and,
      expr: {sql_op_to_ecto_op(operator), [], [field_ref(where_field), param]},
      file: meta[:file],
      line: span_line(meta),
      params: [],
      subqueries: []
    }
  end

  defp merge_range(
         %Ecto.Query.BooleanExpr{
           op: :and,
           expr: {lhs_op, [], [lhs_field_ref, _lhs_param]} = lhs_expr
         } = lhs_bool,
         %Ecto.Query.BooleanExpr{
           op: :and,
           expr: {rhs_op, [], [rhs_field_ref, _rhs_param]} = rhs_expr
         }
       )
       when lhs_op in ~w[> >=]a and rhs_op in ~w[< <=]a and lhs_field_ref == rhs_field_ref do
    [%Ecto.Query.BooleanExpr{lhs_bool | expr: {lhs_expr, rhs_expr}}]
  end

  defp merge_range(lhs, rhs), do: [lhs, rhs]

  defp field_ref(field_atom) do
    {{:., [], [{:&, [], [0]}, field_atom]}, [], []}
  end

  defp token_to_param({:quote, _meta, value}) do
    :erlang.list_to_binary(value)
  end

  defp token_to_param({:paren, _meta, [{:quote, _, part}, {:comma, _, [{:*, _, []}]}]}) do
    {:erlang.list_to_binary(part), :*}
  end

  defp token_to_param({:paren, _meta, [{:quote, _, part}, {:comma, _, [{:numeric, _, n}]}]}) do
    {:erlang.list_to_binary(part), EctoFoundationDB.Versionstamp.from_integer(:erlang.list_to_integer(n))}
  end

  defp sql_op_to_ecto_op(:=), do: :==
  defp sql_op_to_ecto_op(op), do: op

  defp charlist_to_atom(charlist) when is_list(charlist), do: :erlang.list_to_atom(charlist)
  defp charlist_to_atom(atom) when is_atom(atom), do: atom

  defp span_line(meta) do
    case meta[:span] do
      {line, _, _, _, _, _} -> line
      _ -> nil
    end
  end
end
