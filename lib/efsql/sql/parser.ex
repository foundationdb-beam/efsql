defmodule Efsql.SQL.Parser do
  @moduledoc """
  Parses one `SELECT` statement into an `Efsql.SQL.AST.Select`.

      SELECT fields FROM name [WHERE expr] [ORDER BY items] [LIMIT n] [;]

  A recursive-descent parser over `Efsql.SQL.Lexer` tokens. Keywords are
  recognised by position, so a word is only a keyword where the grammar
  expects one. The reserved words below can't be bare names anywhere,
  because a name could be mistaken for them; quote them to use them as
  names (`"order"`). Everything else (`day`, `user`, `date`, `value`, ...)
  is an ordinary name.

  Precedence, loosest first: `OR`, `AND`, `NOT`, then a predicate
  (comparison, `BETWEEN`, `IN`, `LIKE`, `IS NULL`), then `::` casts.
  """

  alias Efsql.SQL.AST
  alias Efsql.SQL.Lexer
  alias Efsql.SQL.SyntaxError

  @reserved ~w[all and as asc between by case cast cross desc distinct else end except
               false from full group having ilike in inner intersect is isnull join
               left like limit not notnull null offset on or order right select then
               true union when where with]

  @not_select ~w[insert update delete create drop alter truncate grant revoke explain]
  @unsupported_clauses %{
    "group" => "GROUP BY",
    "having" => "HAVING",
    "offset" => "OFFSET",
    "join" => "JOIN",
    "inner" => "JOIN",
    "left" => "JOIN",
    "right" => "JOIN",
    "full" => "JOIN",
    "cross" => "JOIN",
    "union" => "UNION",
    "intersect" => "INTERSECT",
    "except" => "EXCEPT",
    "fetch" => "FETCH"
  }

  @comparison_ops [:=, :<>, :<, :>, :<=, :>=]
  @arithmetic_ops [:+, :-, :*, :/, :%]
  @max_depth 200

  def reserved_words, do: @reserved

  @spec parse(String.t()) :: {:ok, AST.Select.t()} | {:error, SyntaxError.t()}
  def parse(sql) when is_binary(sql) do
    with {:ok, tokens} <- Lexer.tokenize(sql) do
      {:ok, statement(tokens)}
    end
  catch
    {:syntax_error, reason, {line, column}} ->
      {:error, %SyntaxError{reason: reason, line: line, column: column}}
  end

  @spec parse!(String.t()) :: AST.Select.t()
  def parse!(sql) do
    case parse(sql) do
      {:ok, select} -> select
      {:error, error} -> raise error
    end
  end

  # -- statement --

  defp statement([{:eof, _, pos}]), do: error("empty statement", pos)

  defp statement(tokens) do
    {select, rest} = select(tokens)

    case rest do
      [{:eof, _, _}] -> select
      [{:op, :";", _}, {:eof, _, _}] -> select
      [{:op, :";", _}, {_, _, pos} | _] -> error("only one statement is supported", pos)
      [token | _] -> end_of_statement_error(token)
    end
  end

  defp end_of_statement_error({:word, word, pos}) when is_map_key(@unsupported_clauses, word) do
    error("#{Map.fetch!(@unsupported_clauses, word)} is not supported", pos)
  end

  defp end_of_statement_error({:op, op, pos}) when op in @arithmetic_ops do
    error("arithmetic is not supported", pos)
  end

  defp end_of_statement_error({_, _, pos} = token) do
    error("expected end of statement, got #{describe(token)}", pos)
  end

  defp select([{:word, "select", _} | rest]) do
    {fields, rest} = select_list(rest)
    rest = expect_keyword(rest, "from", "FROM")
    {from, rest} = table_name(rest)

    case rest do
      [{:op, :",", pos} | _] -> error("selecting from more than one table is not supported", pos)
      _ -> :ok
    end

    {where, rest} = where(rest)
    {order_by, rest} = order_by(rest)
    {limit, rest} = limit(rest)

    {%AST.Select{fields: fields, from: from, where: where, order_by: order_by, limit: limit},
     rest}
  end

  defp select([{:word, word, pos} | _]) when word in @not_select,
    do: error("only SELECT statements are supported", pos)

  defp select([{_, _, pos} = token | _]),
    do: error("expected SELECT, got #{describe(token)}", pos)

  # -- SELECT list --

  defp select_list([{:op, :*, _} | rest]) do
    case rest do
      [{:op, :",", pos} | _] -> error("* can't be combined with other fields", pos)
      _ -> {:star, rest}
    end
  end

  defp select_list([{:word, "distinct", pos} | _]), do: error("DISTINCT is not supported", pos)

  defp select_list(tokens) do
    {name, rest} = name(tokens, "a field name or *")
    rest = reject_qualified_or_call(rest)

    case rest do
      [{:op, :",", _} | rest] ->
        {names, rest} = select_list_rest(rest)
        {[name | names], rest}

      rest ->
        {[name], rest}
    end
  end

  defp select_list_rest(tokens) do
    {name, rest} = name(tokens, "a field name")
    rest = reject_qualified_or_call(rest)

    case rest do
      [{:op, :",", _} | rest] ->
        {names, rest} = select_list_rest(rest)
        {[name | names], rest}

      rest ->
        {[name], rest}
    end
  end

  # -- FROM --

  defp table_name(tokens) do
    {first, rest} = name(tokens, "a table name")
    table_name_parts(rest, [first])
  end

  defp table_name_parts([{:op, :., pos} | rest], parts) do
    if length(parts) == 3 do
      error("a table name has at most three parts (storage_id.tenant.table)", pos)
    end

    {part, rest} = name(rest, "a name after '.'")
    table_name_parts(rest, parts ++ [part])
  end

  defp table_name_parts(rest, parts), do: {parts, rest}

  # -- WHERE --

  defp where([{:word, "where", _} | rest]) do
    {expr, rest} = expr(rest, 0)
    {expr, rest}
  end

  defp where(rest), do: {nil, rest}

  # -- ORDER BY --

  defp order_by([{:word, "order", _} | rest]) do
    rest = expect_keyword(rest, "by", "BY after ORDER")
    order_items(rest)
  end

  defp order_by(rest), do: {[], rest}

  defp order_items(tokens) do
    {name, rest} = name(tokens, "a field name to order by")
    rest = reject_qualified_or_call(rest)

    {dir, rest} =
      case rest do
        [{:word, "asc", _} | rest] -> {:asc, rest}
        [{:word, "desc", _} | rest] -> {:desc, rest}
        rest -> {:asc, rest}
      end

    case rest do
      [{:word, "nulls", pos} | _] ->
        error("NULLS FIRST/LAST is not supported", pos)

      [{:op, :",", _} | rest] ->
        {items, rest} = order_items(rest)
        {[{name, dir} | items], rest}

      rest ->
        {[{name, dir}], rest}
    end
  end

  # -- LIMIT --

  defp limit([{:word, "limit", _} | rest]) do
    case rest do
      [{:integer, n, _} | rest] ->
        {n, rest}

      [{_, _, pos} = token | _] ->
        error("LIMIT expects a whole number, got #{describe(token)}", pos)
    end
  end

  defp limit(rest), do: {nil, rest}

  # -- expressions --

  defp expr(tokens, depth), do: or_expr(tokens, depth)

  defp or_expr(tokens, depth) do
    {left, rest} = and_expr(tokens, depth)
    or_rest(left, rest, depth)
  end

  defp or_rest(left, [{:word, "or", _} | rest], depth) do
    {right, rest} = and_expr(rest, depth)
    or_rest({:or, left, right}, rest, depth)
  end

  defp or_rest(left, rest, _depth), do: {left, rest}

  defp and_expr(tokens, depth) do
    {left, rest} = not_expr(tokens, depth)
    and_rest(left, rest, depth)
  end

  defp and_rest(left, [{:word, "and", _} | rest], depth) do
    {right, rest} = not_expr(rest, depth)
    and_rest({:and, left, right}, rest, depth)
  end

  defp and_rest(left, rest, _depth), do: {left, rest}

  defp not_expr([{:word, "not", pos} | rest], depth) do
    check_depth(depth, pos)
    {expr, rest} = not_expr(rest, depth + 1)
    {{:not, expr}, rest}
  end

  defp not_expr(tokens, depth), do: predicate(tokens, depth)

  defp predicate(tokens, depth) do
    {left, rest} = operand(tokens, depth)

    case rest do
      [{:op, op, _} | rest] when op in @comparison_ops ->
        {right, rest} = operand(rest, depth)
        {{:compare, op, left, right}, rest}

      [{:op, op, pos} | _] when op in @arithmetic_ops ->
        error("arithmetic is not supported", pos)

      [{:word, "not", _}, {:word, word, _} = next | rest]
      when word in ~w[between in like ilike] ->
        negatable(left, next, rest, true, depth)

      [{:word, word, _} = next | rest] when word in ~w[between in like ilike] ->
        negatable(left, next, rest, false, depth)

      [{:word, "is", _} | rest] ->
        is_null(left, rest)

      [{:word, "isnull", _} | rest] ->
        {{:is_null, left, false}, rest}

      [{:word, "notnull", _} | rest] ->
        {{:is_null, left, true}, rest}

      rest ->
        {left, rest}
    end
  end

  defp negatable(left, {:word, "between", _}, rest, negated?, depth) do
    {low, rest} = operand(rest, depth)
    rest = expect_keyword(rest, "and", "AND in BETWEEN")
    {high, rest} = operand(rest, depth)
    {{:between, left, low, high, negated?}, rest}
  end

  defp negatable(left, {:word, "in", _}, rest, negated?, depth) do
    case rest do
      [{:op, :"(", pos}, {:op, :")", _} | _] ->
        error("IN needs at least one value", pos)

      [{:op, :"(", pos} | rest] ->
        check_depth(depth, pos)
        {values, rest} = expr_list(rest, depth + 1)
        rest = expect_op(rest, :")", "')' to close the IN list")
        {{:in, left, values, negated?}, rest}

      [{_, _, pos} = token | _] ->
        error("expected '(' after IN, got #{describe(token)}", pos)
    end
  end

  defp negatable(left, {:word, like, _}, rest, negated?, depth) when like in ~w[like ilike] do
    {pattern, rest} = operand(rest, depth)
    {{String.to_atom(like), left, pattern, negated?}, rest}
  end

  defp is_null(left, rest) do
    {negated?, rest} =
      case rest do
        [{:word, "not", _} | rest] -> {true, rest}
        rest -> {false, rest}
      end

    case rest do
      [{:word, "null", _} | rest] ->
        {{:is_null, left, negated?}, rest}

      [{_, _, pos} = token | _] ->
        error("expected NULL after IS#{if negated?, do: " NOT"}, got #{describe(token)}", pos)
    end
  end

  defp expr_list(tokens, depth) do
    {expr, rest} = expr(tokens, depth)

    case rest do
      [{:op, :",", _} | rest] ->
        {exprs, rest} = expr_list(rest, depth)
        {[expr | exprs], rest}

      rest ->
        {[expr], rest}
    end
  end

  # An operand is a primary followed by any number of `::type` casts.
  defp operand(tokens, depth) do
    {primary, rest} = primary(tokens, depth)
    casts(primary, rest)
  end

  defp casts(expr, [{:op, :"::", _} | rest]) do
    {type, rest} = type_name(rest)
    casts({:cast, expr, type}, rest)
  end

  defp casts(expr, rest), do: {expr, rest}

  defp primary([{:string, s, _} | rest], _depth), do: {{:literal, s}, rest}
  defp primary([{:integer, n, _} | rest], _depth), do: {{:literal, n}, rest}
  defp primary([{:float, f, _} | rest], _depth), do: {{:literal, f}, rest}

  defp primary([{:op, :-, _}, {type, n, _} | rest], _depth) when type in [:integer, :float],
    do: {{:literal, -n}, rest}

  defp primary([{:op, :+, _}, {type, n, _} | rest], _depth) when type in [:integer, :float],
    do: {{:literal, n}, rest}

  defp primary([{:op, sign, pos} | _], _depth) when sign in [:-, :+],
    do: error("a sign is only supported on a number", pos)

  defp primary([{:word, "true", _} | rest], _depth), do: {{:literal, true}, rest}
  defp primary([{:word, "false", _} | rest], _depth), do: {{:literal, false}, rest}
  defp primary([{:word, "null", _} | rest], _depth), do: {{:literal, nil}, rest}

  defp primary([{:word, "select", pos} | _], _depth),
    do: error("subqueries are not supported", pos)

  defp primary([{:word, "cast", _}, {:op, :"(", pos} | rest], depth) do
    check_depth(depth, pos)
    {expr, rest} = expr(rest, depth + 1)
    rest = expect_keyword(rest, "as", "AS in CAST")
    {type, rest} = type_name(rest)
    rest = expect_op(rest, :")", "')' to close CAST")
    {{:cast, expr, type}, rest}
  end

  defp primary([{:op, :"(", pos} | rest], depth) do
    check_depth(depth, pos)
    {first, rest} = paren_element(rest, depth + 1)

    case rest do
      [{:op, :",", _} | rest] ->
        {elements, rest} = tuple_elements(rest, depth + 1)
        rest = expect_op(rest, :")", "')' to close the tuple")
        {{:tuple, [first | elements]}, rest}

      rest ->
        if first == :star, do: error("'*' is only allowed in a tuple", pos)
        rest = expect_op(rest, :")", "')'")
        {first, rest}
    end
  end

  defp primary([{:word, word, pos} | _] = tokens, _depth) when word not in @reserved do
    {name, rest} = name(tokens, "an expression")

    case rest do
      [{:op, :"(", _} | _] -> error("functions are not supported", pos)
      [{:op, :., dot} | _] -> error("qualified column names are not supported", dot)
      rest -> {{:column, name}, rest}
    end
  end

  defp primary([{:quoted, _, _} | _] = tokens, _depth) do
    {name, rest} = name(tokens, "an expression")
    {{:column, name}, reject_qualified_or_call(rest)}
  end

  defp primary([{_, _, pos} = token | _], _depth),
    do: error("expected an expression, got #{describe(token)}", pos)

  defp paren_element([{:op, :*, _} | rest], _depth), do: {:star, rest}
  defp paren_element(tokens, depth), do: expr(tokens, depth)

  defp tuple_elements(tokens, depth) do
    {element, rest} = paren_element(tokens, depth)

    case rest do
      [{:op, :",", _} | rest] ->
        {elements, rest} = tuple_elements(rest, depth)
        {[element | elements], rest}

      rest ->
        {[element], rest}
    end
  end

  # A type is any word (reserved ones like date and time included), with
  # PostgreSQL's `timestamp with[out] time zone` spelled out.
  defp type_name([{:word, type, _} | rest]) when type in ~w[timestamp time] do
    case rest do
      [{:word, "with", _}, {:word, "time", _}, {:word, "zone", _} | rest] -> {type <> "tz", rest}
      [{:word, "without", _}, {:word, "time", _}, {:word, "zone", _} | rest] -> {type, rest}
      rest -> {type, rest}
    end
  end

  defp type_name([{:word, type, _} | rest]), do: {type, rest}

  defp type_name([{_, _, pos} = token | _]),
    do: error("expected a type name, got #{describe(token)}", pos)

  # -- names --

  defp name([{:word, word, pos} | _], what) when word in @reserved do
    error(
      "expected #{what}, got the keyword '#{word}' (quote it, \"#{word}\", to use it as a name)",
      pos
    )
  end

  defp name([{:word, word, _} | rest], _what), do: {word, rest}
  defp name([{:quoted, name, _} | rest], _what), do: {name, rest}

  defp name([{_, _, pos} = token | _], what),
    do: error("expected #{what}, got #{describe(token)}", pos)

  defp reject_qualified_or_call([{:op, :"(", pos} | _]),
    do: error("functions are not supported", pos)

  defp reject_qualified_or_call([{:op, :., pos} | _]),
    do: error("qualified column names are not supported", pos)

  defp reject_qualified_or_call(rest), do: rest

  # -- helpers --

  defp expect_keyword([{:word, word, _} | rest], word, _what), do: rest

  defp expect_keyword([{_, _, pos} = token | _], _word, what),
    do: error("expected #{what}, got #{describe(token)}", pos)

  defp expect_op([{:op, op, _} | rest], op, _what), do: rest

  defp expect_op([{_, _, pos} = token | _], _op, what),
    do: error("expected #{what}, got #{describe(token)}", pos)

  defp check_depth(depth, pos) do
    if depth >= @max_depth, do: error("expression is nested too deeply", pos)
  end

  defp describe({:word, word, _}), do: "'#{word}'"
  defp describe({:quoted, name, _}), do: inspect(name)
  defp describe({:string, s, _}), do: "the string '#{truncate(s)}'"
  defp describe({type, n, _}) when type in [:integer, :float], do: "the number #{n}"
  defp describe({:op, op, _}), do: "'#{op}'"
  defp describe({:eof, _, _}), do: "the end of the statement"

  defp truncate(s) do
    if String.length(s) > 20, do: String.slice(s, 0, 20) <> "...", else: s
  end

  defp error(reason, pos), do: throw({:syntax_error, reason, pos})
end
