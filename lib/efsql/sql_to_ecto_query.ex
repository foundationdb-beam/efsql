defmodule Efsql.SqlToEctoQuery do
  alias Efsql.Exception.Unsupported

  @operator_map %{=: :==}

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
    expr = for field <- field_names, do: field_name_select_expr(field)

    %Ecto.Query{
      query
      | select: %Ecto.Query.SelectExpr{
          expr: expr,
          file: meta[:file],
          line: meta[:line],
          fields: field_names,
          params: [],
          take: %{},
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
    # IO.inspect(token, label: "query")

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

  # @todo: not all strings are given as `:ident` tokens. For example, using
  # 'select id, name from t.users' yields `:name` instead of `:ident`
  # https://github.com/elixir-dbvisor/sql/issues/13
  defp get_ident_atom({:ident, _meta, [field_name]}), do: to_atom(field_name)
  defp get_ident_atom({reserved, _meta, []}), do: to_atom(reserved)

  defp get_ident_atom({token, _meta, args}) do
    raise Unsupported, """
    Expected an identifier, got #{token}/#{length(args)} instead.
    """
  end

  defp from_tokens_to_source([
         {:., _meta0,
          [{_ident_or_double_quote, _meta1, [_tenant_id]}, {:ident, _meta2, [source]}]}
         | _optional_source_alias_ident
       ])
       when is_binary(source) do
    {source, nil}
  end

  defp from_tokens_to_source([{:ident, [line: 0, column: 25, file: {1, 0, nil}], [source]}])
       when is_binary(source) do
    {source, nil}
  end

  defp from_tokens_to_prefix([
         {:., _meta0,
          [{_ident_or_double_quote, _meta1, [tenant_id]}, {:ident, _meta2, [_source]}]}
         | _optional_source_alias_ident
       ])
       when is_binary(tenant_id) do
    tenant_id
  end

  defp from_tokens_to_prefix(_), do: nil

  defp where_tokens_to_wheres([], acc) do
    Enum.reverse(acc)
  end

  defp where_tokens_to_wheres([op_token = {operator, _meta, [_lhs, _rhs]} | rest], acc)
       when operator in ~w[= >= <= > < !=]a do
    expr = operator_to_where_expr(op_token)
    acc = merge_operator_head(expr, acc)
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

  defp field_name_select_expr(atom_field) do
    {:{}, [], [atom_field, {{:., [], [{:&, [], [0]}, atom_field]}, [], []}]}
  end

  defp to_atom(atom) when is_atom(atom), do: atom
  defp to_atom(string) when is_binary(string), do: String.to_atom(string)

  defp sql_operator_to_ecto_operator(operator) do
    Map.get(@operator_map, operator, operator)
  end

  defp get_where_param({:quote, _, [data]}) do
    data
  end
end
