defmodule Efsql.SqlToEctoQuery do
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

  defp token_to_ecto_query(_token, query) do
    query
  end

  defp select_tokens_to_expr([{:*, _meta, []}], _acc) do
    raise """
    The 'select' expression must have a list of fields. '*' is not supported
    """
  end

  defp select_tokens_to_expr([{:ident, _meta, [field_name]} | rest], acc) do
    select_tokens_to_expr(rest, [to_atom(field_name) | acc])
  end

  defp select_tokens_to_expr([{:comma, _meta, [following_comma]} | rest], acc) do
    [item] = select_tokens_to_expr([following_comma], [])
    select_tokens_to_expr(rest, [item | acc])
  end

  defp select_tokens_to_expr([{field_name, _meta, []} | rest], acc) do
    # @todo: not all strings are given as `:ident` tokens. For example, using
    # 'select id, name from t.users' yields `:name` instead of `:ident`
    select_tokens_to_expr(rest, [to_atom(field_name) | acc])
  end

  defp select_tokens_to_expr(_t, acc) do
    # IO.inspect(t, label: "skip")
    Enum.reverse(acc)
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

  defp field_name_select_expr(atom_field) do
    {:{}, [], [atom_field, {{:., [], [{:&, [], [0]}, atom_field]}, [], []}]}
  end

  defp to_atom(atom) when is_atom(atom), do: atom
  defp to_atom(string) when is_binary(string), do: String.to_atom(string)
end
