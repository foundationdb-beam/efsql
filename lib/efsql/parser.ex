defmodule Efsql.Parser do
  @moduledoc """
  Converts the SQL library's parse tree into an `Efsql.Logical.Select`.
  Purely syntactic — normalization (range merging, LIKE rewriting) happens
  in `Efsql.Rewrite`.
  """

  alias Efsql.Exception.Unsupported
  alias Efsql.Logical
  alias Efsql.Types

  @comparison_ops ~w[= >= <= > <]a

  # Tokens that follow a column: an unquoted column named after a reserved
  # word (day, at, date, user, ...) is recognised by its position here.
  @column_followers ~w[= != <> < > <= >= in like ilike between is not asc desc]a
  # Reserved words that can themselves precede one of those tokens.
  @not_columns ~w[true false null unknown end case when then else where having on select is]a

  @doc """
  Lexes and parses SQL text into the SQL library's parse tree, as
  `{:ok, context, parsed}`. Use this rather than calling the library
  directly: it first rewrites token sequences the library mishandles.
  """
  def parse(sql) do
    {:ok, context, tokens} = SQL.Lexer.lex(sql)
    SQL.Parser.parse(normalize_tokens(tokens), context)
  end

  def sql_to_logical(sql) do
    {:ok, _context, parsed} = parse(sql)
    to_logical(parsed)
  end

  # The library lexes a reserved word as its own token even where it names
  # a column, and then misparses the predicate or never returns from
  # `where day = 'x'`. A reserved word right before a column follower is
  # a column: rewrite it to the identifier the library expects.
  #
  # The library assembles `x is null` into a node that composes with `and`,
  # but leaves `x is not null` as loose tokens, and never returns from
  # `... and x is not null`; its postfix `isnull`/`notnull` nodes hang the
  # same way. Rewrite all of them to the `is null` shape, marking the
  # negated ones on the `is` token's meta. The marker is appended because
  # the library matches the leading meta entries by position. Lexer tokens
  # are in reverse order.
  defp normalize_tokens([{:null, _, []} = null, {:not, _, []}, {:is, meta, []} | rest]) do
    [null | normalize_tokens([{:is, meta ++ [efsql_not_null: true], []} | rest])]
  end

  defp normalize_tokens([{tag, meta, []} | rest]) when tag in ~w[isnull notnull]a do
    is_meta = List.keyreplace(meta, :type, 0, {:type, :operator})
    is_meta = if tag == :notnull, do: is_meta ++ [efsql_not_null: true], else: is_meta
    [{:null, meta, []} | normalize_tokens([{:is, is_meta, []} | rest])]
  end

  defp normalize_tokens([{tag, meta, data} | rest]) when tag in ~w[paren bracket brace]a do
    [{tag, meta, normalize_tokens(data)} | normalize_tokens(rest)]
  end

  defp normalize_tokens([token, {word, meta, []} | rest])
       when is_atom(word) and word not in @not_columns do
    if column_follower?(token) and meta[:type] == :reserved do
      ident = {:ident, List.keyreplace(meta, :type, 0, {:type, :literal}), Atom.to_charlist(word)}
      [token | normalize_tokens([ident | rest])]
    else
      [token | normalize_tokens([{word, meta, []} | rest])]
    end
  end

  defp normalize_tokens([token | rest]), do: [token | normalize_tokens(rest)]
  defp normalize_tokens([]), do: []

  # Non-reserved words such as asc and desc lex as identifiers carrying
  # the word in their meta's :tag.
  defp column_follower?({:ident, meta, _}), do: meta[:tag] in @column_followers
  defp column_follower?({tag, _meta, _}), do: tag in @column_followers

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

  defp from_token_to_prefix(
         {:dot, _meta, [{_st, _sm, storage}, {:dot, _, [{_tt, _tm, tenant}, _table]}]}
       ) do
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

  defp conjunct({:is, meta, [field, {:null, _null_meta, []}]}) do
    case field_atom(field) do
      :_ -> raise Unsupported, "the primary key '_' is never NULL"
      field -> if meta[:efsql_not_null], do: {:not_null, field}, else: {:is_null, field}
    end
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

  defp param({:integer, _meta, value}), do: :erlang.list_to_integer(value)

  # sql 0.5.0 lexes integers as :numeric too.
  defp param({:numeric, _meta, value}) do
    value = :erlang.list_to_binary(value)

    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> String.to_float(value)
    end
  end

  # 'value'::type and cast('value' as type) -- see Efsql.Types
  defp param({:"::", _meta, [value, type]}), do: Types.cast(type_name(type), param(value))

  defp param({:cast, _meta, [{:paren, _paren_meta, [{:as, _as_meta, [value, type]}]}]}) do
    Types.cast(type_name(type), param(value))
  end

  defp param({true, _meta, []}), do: true
  defp param({false, _meta, []}), do: false
  # SQL's `x = null` is never true, which is never what was meant.
  defp param({:null, _meta, []}) do
    raise Unsupported, "a comparison with NULL is never true; use IS NULL or IS NOT NULL"
  end

  defp param({:paren, _meta, [{:quote, _, part}, {:comma, _, [{:*, _, []}]}]}) do
    {:erlang.list_to_binary(part), :*}
  end

  defp param({:paren, _meta, [{:quote, _, part}, {:comma, _, [{tag, _, n}]}]})
       when tag in ~w[integer numeric]a do
    {:erlang.list_to_binary(part),
     EctoFoundationDB.Versionstamp.from_integer(:erlang.list_to_integer(n))}
  end

  # Non-reserved words lex as identifiers, reserved ones (e.g. `date`) as
  # their own token.
  defp type_name({tag, _meta, name}) when tag in ~w[ident double_quote]a do
    name |> List.to_string() |> String.downcase()
  end

  defp type_name({tag, _meta, []}) when is_atom(tag), do: Atom.to_string(tag)

  defp sql_op(:=), do: :==
  defp sql_op(op), do: op

  defp charlist_to_atom(charlist) when is_list(charlist), do: :erlang.list_to_atom(charlist)
  defp charlist_to_atom(atom) when is_atom(atom), do: atom
end
