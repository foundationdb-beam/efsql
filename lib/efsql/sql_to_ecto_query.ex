defmodule Efsql.SqlToEctoQuery do
  alias Efsql.Exception.Unsupported

  @operator_map %{=: :==, dot: :.}

  def to_ecto_query(tokens) do
    reduce(tokens, %Ecto.Query{}, &token_to_ecto_query/2)
  end

  defp reduce(tokens, acc, fun) do
    Enum.reduce(tokens, acc, fn token, acc0 ->
      fun.(token, acc0)
    end)
  end

  defp token_to_ecto_query({:select, meta, tokens}, query) do
    field_names = select_tokens_to_expr(tokens, [])

    %Ecto.Query{
      query
      | select: %Ecto.Query.SelectExpr{
          expr: {:&, [], [0]},
          file: meta[:file],
          line: meta[:line],
          fields: nil,
          params: [],
          take: %{0 => {:any, field_names}},
          subqueries: [],
          aliases: %{}
        }
    }
  end

  defp token_to_ecto_query({:from, meta, tokens}, query) do
    %Ecto.Query{
      query
      | from: %Ecto.Query.FromExpr{
          source: from_tokens_to_source(tokens),
          file: meta[:file],
          line: meta[:line],
          as: nil,
          prefix: nil,
          params: [],
          hints: []
        },
        prefix: from_tokens_to_prefix(tokens)
    }
  end

  defp token_to_ecto_query({:where, _meta, tokens}, query) do
    %Ecto.Query{
      query
      | wheres: where_tokens_to_wheres(tokens, [])
    }
  end

  defp token_to_ecto_query({:colon, _meta, []}, query) do
    query
  end

  defp token_to_ecto_query({token, _, _}, _query) do
    raise Unsupported, """
    '#{token}' is not supported
    """
  end

  defp select_tokens_to_expr([], acc) do
    Enum.reverse(acc)
  end

  defp select_tokens_to_expr([{:*, _meta, []}], _acc) do
    raise Unsupported, """
    The 'select' expression must have a list of fields. '*' is not supported
    """
  end

  defp select_tokens_to_expr([{:comma, _meta, [following_comma]} | rest], acc) do
    [item] = select_tokens_to_expr([following_comma], [])
    select_tokens_to_expr(rest, [item | acc])
  end

  defp select_tokens_to_expr([ident_token | rest], acc) do
    select_tokens_to_expr(rest, [get_ident_atom(ident_token) | acc])
  end

  defp get_ident_atom({:ident, _meta, field_name}), do: to_atom(field_name)

  defp get_ident_atom({token, _meta, args}) do
    raise Unsupported, """
    Expected an identifier, got #{token}/#{length(args)} instead.
    """
  end

  defp from_tokens_to_source([
         {:dot, _meta0, [{_ident_or_double_quote, _meta1, _tenant_id}, {:ident, _meta2, source}]}
         | _optional_source_alias_ident
       ])
       when is_list(source) do
    {:erlang.iolist_to_binary(source), nil}
  end

  defp from_tokens_to_source([{:ident, _meta, source}])
       when is_list(source) do
    {:erlang.iolist_to_binary(source), nil}
  end

  defp from_tokens_to_prefix([
         {:dot, _meta0, [{_ident_or_double_quote, _meta1, tenant_id}, {:ident, _meta2, _source}]}
         | _optional_source_alias_ident
       ])
       when is_list(tenant_id) do
    :erlang.iolist_to_binary(tenant_id)
  end

  defp from_tokens_to_prefix(_), do: nil

  defp where_tokens_to_wheres([], acc) do
    Enum.reverse(acc)
  end

  defp where_tokens_to_wheres(
         [{:primary, meta0, []}, {operator, meta2, []}, rhs | rest],
         acc
       )
       when operator in ~w[= > < >= <=]a do
    lhs = {:ident, meta0, :_}
    op_token = {operator, meta2, [lhs, rhs]}
    expr = operator_to_where_expr(op_token)
    acc = merge_operator_head(expr, acc)
    where_tokens_to_wheres(rest, acc)
  end

  defp where_tokens_to_wheres([op_token = {operator, _meta, [_lhs, _rhs]} | rest], acc)
       when operator in ~w[= >= <= > <]a do
    expr = operator_to_where_expr(op_token)
    acc = merge_operator_head(expr, acc)
    where_tokens_to_wheres(rest, acc)
  end

  defp where_tokens_to_wheres([{:and, _meta, []} | rest], acc) do
    where_tokens_to_wheres(rest, acc)
  end

  defp where_tokens_to_wheres([{:and, _meta, rest}], acc) do
    where_tokens_to_wheres(rest, acc)
  end

  defp where_tokens_to_wheres([{operator, _meta, operands} | _], _acc) do
    raise Unsupported, """
    '#{inspect(operator)}'/#{length(operands)} is not supported in the where clause.
    """
  end

  # @todo We are very specific in our supported operators in EctoFDB, which forces this merge
  defp merge_operator_head(
         %Ecto.Query.BooleanExpr{
           op: :and,
           expr:
             expr_rhs =
               {between_op_rhs, [], [{{:., [], [{:&, [], [0]}, field_name]}, [], []}, _param_b]}
         },
         [
           head = %Ecto.Query.BooleanExpr{
             op: :and,
             expr:
               expr_lhs =
                 {between_op_lhs, [], [{{:., [], [{:&, [], [0]}, field_name]}, [], []}, _param_a]}
           }
           | acc
         ]
       )
       when between_op_lhs in ~w[> >=]a and between_op_rhs in ~w[< <=]a do
    [
      %Ecto.Query.BooleanExpr{
        head
        | expr: {expr_lhs, expr_rhs}
      }
      | acc
    ]
  end

  defp merge_operator_head(expr, acc) do
    [expr | acc]
  end

  # @todo: Is this a bug in the AST? Sort of awkward construction of the boolean operators, hard to generalize
  defp operator_to_where_expr(
         {op_2, meta, [{:and, _meta1, [{op_1, _meta2, [lhs_1, rhs_1]}, lhs_2]}, rhs_2]}
       ) do
    where_field_1 = get_ident_atom(lhs_1)
    where_field_2 = get_ident_atom(lhs_2)
    where_param_1 = get_where_param(rhs_1)
    where_param_2 = get_where_param(rhs_2)

    expr_1 =
      {sql_operator_to_ecto_operator(op_1), [],
       [{{:dot, [], [{:&, [], [0]}, where_field_1]}, [], []}, where_param_1]}

    expr_2 =
      {sql_operator_to_ecto_operator(op_2), [],
       [{{:dot, [], [{:&, [], [0]}, where_field_2]}, [], []}, where_param_2]}

    %Ecto.Query.BooleanExpr{
      op: :and,
      expr: {expr_1, expr_2},
      file: meta[:file],
      line: meta[:line],
      params: [],
      subqueries: []
    }
  end

  defp operator_to_where_expr({operator, meta, [lhs, rhs]}) do
    where_field = get_ident_atom(lhs)
    where_param = get_where_param(rhs)

    expr =
      {sql_operator_to_ecto_operator(operator), [],
       [{{:., [], [{:&, [], [0]}, where_field]}, [], []}, where_param]}

    %Ecto.Query.BooleanExpr{
      op: :and,
      expr: expr,
      file: meta[:file],
      line: meta[:line],
      params: [],
      subqueries: []
    }
  end

  defp to_atom(atom) when is_atom(atom), do: atom
  defp to_atom(string) when is_binary(string), do: String.to_atom(string)
  defp to_atom(list) when is_list(list), do: :erlang.iolist_to_binary(list) |> to_atom()

  defp sql_operator_to_ecto_operator(operator) do
    Map.get(@operator_map, operator, operator)
  end

  defp get_where_param({:quote, _, data}) do
    :erlang.iolist_to_binary(data)
  end
end
