defmodule Efsql.Parser do
  @moduledoc """
  Converts the SQL library's parse tree into an `Efsql.Logical.Select`.
  Purely syntactic — normalization (range merging, LIKE rewriting) happens
  in `Efsql.Rewrite`.
  """

  alias Efsql.Exception.Unsupported
  alias Efsql.Logical

  @comparison_ops ~w[= >= <= > <]a

  def to_logical(parsed) do
    parsed
    |> Enum.reject(fn
      {:colon, _, _} -> true
      [] -> true
      _ -> false
    end)
    |> Enum.reduce(%Logical.Select{}, &clause/2)
  end

  defp clause({:select, _meta, fields}, %Logical.Select{} = select) do
    %Logical.Select{select | projection: parse_select_fields(fields, [])}
  end

  defp clause({:from, _meta, [source_token | _]}, %Logical.Select{} = select) do
    %Logical.Select{
      select
      | source: from_token_to_source(source_token),
        prefix: from_token_to_prefix(source_token)
    }
  end

  defp clause({:where, _meta, [expr]}, %Logical.Select{} = select) do
    %Logical.Select{select | predicates: expr |> flatten_and() |> Enum.map(&conjunct/1)}
  end

  defp clause({:order, _meta, [{:by, _by_meta, items}]}, %Logical.Select{} = select) do
    %Logical.Select{select | order: Enum.map(items, &order_item/1)}
  end

  defp clause({:limit, _meta, [{tag, _nmeta, value}]}, %Logical.Select{} = select)
       when tag in ~w[integer numeric]a do
    %Logical.Select{select | limit: :erlang.list_to_integer(value)}
  end

  defp clause({token, _, _}, %Logical.Select{}) do
    raise Unsupported, "'#{token}' is not supported"
  end

  # SELECT

  defp parse_select_fields([], acc), do: Enum.reverse(acc)

  defp parse_select_fields([{:*, _, []} | _], _acc), do: :star

  defp parse_select_fields([{:comma, _meta, [field]} | rest], acc) do
    parse_select_fields(rest, [field_atom(field) | acc])
  end

  defp parse_select_fields([field | rest], acc) do
    parse_select_fields(rest, [field_atom(field) | acc])
  end

  defp field_atom({:ident, _meta, value}), do: charlist_to_atom(value)
  defp field_atom({:double_quote, _meta, value}), do: charlist_to_atom(value)
  defp field_atom({token, _meta, []}), do: token

  defp field_atom({token, _meta, args}) do
    raise Unsupported, "Expected an identifier, got #{token}/#{length(args)} instead."
  end

  # FROM

  defp from_token_to_source({:dot, _meta, [_storage, {:dot, _, [_tenant, {:ident, _m, table}]}]}) do
    :erlang.list_to_binary(table)
  end

  defp from_token_to_source({:dot, _meta, [_schema, {:ident, _m, table}]}) do
    :erlang.list_to_binary(table)
  end

  defp from_token_to_source({:ident, _meta, table}) do
    :erlang.list_to_binary(table)
  end

  defp from_token_to_prefix({:dot, _meta, [{_st, _sm, storage}, {:dot, _, [{_tt, _tm, tenant}, _table]}]}) do
    {:erlang.list_to_binary(storage), :erlang.list_to_binary(tenant)}
  end

  defp from_token_to_prefix({:dot, _meta, [{_tag, _m, schema}, _table]}) do
    :erlang.list_to_binary(schema)
  end

  defp from_token_to_prefix(_), do: nil

  # WHERE

  defp flatten_and({:and, _meta, [lhs, rhs]}), do: flatten_and(lhs) ++ flatten_and(rhs)
  defp flatten_and(other), do: [other]

  defp conjunct({operator, _meta, [lhs, rhs]}) when operator in @comparison_ops do
    {:cmp, sql_op(operator), field_atom(lhs), param(rhs)}
  end

  defp conjunct({:between, _meta, [field, {:and, _and_meta, [rhs1, rhs2]}]}) do
    {:range, field_atom(field), {:>=, param(rhs1)}, {:<=, param(rhs2)}}
  end

  defp conjunct({:like, _meta, [{:not, _not_meta, [field]}, pattern]}) do
    {:not_like, field_atom(field), param(pattern)}
  end

  defp conjunct({:like, _meta, [field, pattern]}) do
    {:like, field_atom(field), param(pattern)}
  end

  defp conjunct({:in, _meta, [field, {:paren, _paren_meta, items}]}) do
    values =
      items
      |> Enum.map(fn
        {:comma, _, [item]} -> item
        item -> item
      end)
      |> Enum.map(&param/1)

    {:in, field_atom(field), values}
  end

  defp conjunct({token, _meta, args}) do
    raise Unsupported, "'#{token}'/#{length(args)} is not supported in the where clause."
  end

  # ORDER BY

  defp order_item({:comma, _meta, [item]}), do: order_item(item)
  defp order_item({:asc, _meta, [field]}), do: {:asc, field_atom(field)}
  defp order_item({:desc, _meta, [field]}), do: {:desc, field_atom(field)}
  defp order_item(field), do: {:asc, field_atom(field)}

  # values

  defp param({:quote, _meta, value}) do
    :erlang.list_to_binary(value)
  end

  defp param({:paren, _meta, [{:quote, _, part}, {:comma, _, [{:*, _, []}]}]}) do
    {:erlang.list_to_binary(part), :*}
  end

  defp param({:paren, _meta, [{:quote, _, part}, {:comma, _, [{tag, _, n}]}]})
       when tag in ~w[integer numeric]a do
    {:erlang.list_to_binary(part), EctoFoundationDB.Versionstamp.from_integer(:erlang.list_to_integer(n))}
  end

  defp sql_op(:=), do: :==
  defp sql_op(op), do: op

  defp charlist_to_atom(charlist) when is_list(charlist), do: :erlang.list_to_atom(charlist)
  defp charlist_to_atom(atom) when is_atom(atom), do: atom
end
