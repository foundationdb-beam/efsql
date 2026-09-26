defmodule Efsql.SQL.Yecc.Explain do
  @moduledoc false
  # Words for a yecc syntax error. yecc says only which token it stopped
  # at; Efsql.SQL.Parser says what it expected there. This reconstructs
  # that from the tokens before the error: which clause it is in, what
  # the previous token asks for, and which parenthesis is still open.
  #
  # In a few places the LALR parser reads further than the hand-written
  # one before failing (an infix `not` that isn't NOT IN/LIKE/BETWEEN, a
  # half-written `timestamp with time zone`); there it steps back to the
  # token Efsql.SQL.Parser would have stopped at.

  @reserved Efsql.SQL.Parser.reserved_words()
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
  @comparisons [:=, :<>, :<, :>, :<=, :>=]
  @arithmetic [:+, :-, :*, :/, :%]
  @clauses ~w[select from where order limit]

  @doc "The reason and position Efsql.SQL.Parser gives for the error yecc hit at token `index`."
  def explain(tokens, index), do: at(List.to_tuple(tokens), index)

  defp at(t, 0) do
    case elem(t, 0) do
      {:eof, _, pos} -> {"empty statement", pos}
      {:word, word, pos} when word in @not_select -> {"only SELECT statements are supported", pos}
      token -> expected("SELECT", token)
    end
  end

  defp at(t, i) do
    case elem(t, i - 1) do
      {:op, :";", _} -> {"only one statement is supported", pos(elem(t, i))}
      _ -> in_clause(t, i, clause(t, i))
    end
  end

  # The clause the error is in: the last clause keyword before it, not
  # counting type names (`::order` is a type).
  defp clause(t, i) do
    Enum.reduce(1..(i - 1)//1, {"select", 0}, fn j, acc ->
      case elem(t, j) do
        {:word, word, _} when word in @clauses ->
          if type_position?(t, j), do: acc, else: {word, j}

        _ ->
          acc
      end
    end)
  end

  # -- SELECT list --

  defp in_clause(t, i, {"select", _}) do
    token = elem(t, i)

    case {i, elem(t, i - 1), token} do
      {1, _, {:word, "distinct", pos}} -> {"DISTINCT is not supported", pos}
      {1, _, _} -> name_error(token, "a field name or *")
      {2, {:op, :*, _}, {:op, :",", pos}} -> {"* can't be combined with other fields", pos}
      {2, {:op, :*, _}, _} -> expected("FROM", token)
      {_, {:op, :",", _}, _} -> name_error(token, "a field name")
      {_, _, {:op, :"(", pos}} -> {"functions are not supported", pos}
      {_, _, {:op, :., pos}} -> {"qualified column names are not supported", pos}
      _ -> expected("FROM", token)
    end
  end

  # -- FROM --

  defp in_clause(t, i, {"from", f}) do
    token = elem(t, i)

    case {elem(t, i - 1), token} do
      {{:word, "from", _}, _} ->
        name_error(token, "a table name")

      {{:op, :., _}, _} ->
        name_error(token, "a name after '.'")

      {_, {:op, :., pos}} when i - f == 6 ->
        {"a table name has at most three parts (storage_id.tenant.table)", pos}

      {_, {:op, :",", pos}} ->
        {"selecting from more than one table is not supported", pos}

      _ ->
        end_of_statement(token)
    end
  end

  # -- ORDER BY --

  defp in_clause(t, i, {"order", o}) do
    token = elem(t, i)

    case {elem(t, i - 1), token} do
      {_, _} when i == o + 1 -> expected("BY after ORDER", token)
      {{:word, "by", _}, _} -> name_error(token, "a field name to order by")
      {{:op, :",", _}, _} -> name_error(token, "a field name to order by")
      {{:word, dir, _}, {:word, "nulls", pos}} when dir in ~w[asc desc] -> nulls(pos)
      {{:word, dir, _}, _} when dir in ~w[asc desc] -> end_of_statement(token)
      {_, {:op, :"(", pos}} -> {"functions are not supported", pos}
      {_, {:op, :., pos}} -> {"qualified column names are not supported", pos}
      {_, {:word, "nulls", pos}} -> nulls(pos)
      _ -> end_of_statement(token)
    end
  end

  # -- LIMIT --

  defp in_clause(t, i, {"limit", l}) do
    token = elem(t, i)

    if i == l + 1,
      do: {"LIMIT expects a whole number, got #{describe(token)}", pos(token)},
      else: end_of_statement(token)
  end

  # -- WHERE --

  defp in_clause(t, i, {"where", w}) do
    token = elem(t, i)
    prev = elem(t, i - 1)

    cond do
      k = half_type(t, i) ->
        at(t, k)

      # A type name can be any word (`x::or`); it is never a keyword.
      type_position?(t, i - 1) ->
        after_operand(t, w, i)

      word?(prev, "is") ->
        expected("NULL after IS", token)

      word?(prev, "not") and word?(elem(t, i - 2), "is") ->
        expected("NULL after IS NOT", token)

      word?(prev, "not") and not operand_expected_after?(elem(t, i - 2)) and
          not word?(token, ~w[between in like ilike]) ->
        at(t, i - 1)

      word?(prev, "cast") and not op?(token, :"(") ->
        {"expected an expression, got 'cast'", pos(prev)}

      op?(prev, [:-, :+]) and operand_expected_after?(elem(t, i - 2)) ->
        {"a sign is only supported on a number", pos(prev)}

      op?(prev, :"::") or (word?(prev, "as") and in_cast?(t, w, i)) ->
        expected("a type name", token)

      word?(prev, "in") ->
        expected("'(' after IN", token)

      op?(prev, :"(") and op?(token, :")") and word?(elem(t, i - 2), "in") ->
        {"IN needs at least one value", pos(prev)}

      operand_expected_after?(prev) ->
        case token do
          {:word, "select", pos} -> {"subqueries are not supported", pos}
          _ -> expected("an expression", token)
        end

      true ->
        after_operand(t, w, i)
    end
  end

  # Something complete comes before the token: a name, a literal, a
  # parenthesized expression, a whole predicate.
  defp after_operand(t, w, i) do
    token = elem(t, i)
    prev = elem(t, i - 1)
    start = operand_start(t, i - 1)
    before = elem(t, start - 1)

    cond do
      # A tuple's `*`, the type in CAST(x AS type), or the end of a whole
      # predicate: what follows is the group's business.
      op?(prev, :*) or type_after_as?(t, i - 1) or ends_predicate?(t, i - 1) ->
        in_group(t, w, i)

      name_primary?(t, i - 1) and op?(token, :"(") ->
        {"functions are not supported",
         if(match?({:quoted, _, _}, prev), do: pos(token), else: pos(prev))}

      name_primary?(t, i - 1) and op?(token, :.) ->
        {"qualified column names are not supported", pos(token)}

      word?(before, "between") ->
        expected("AND in BETWEEN", token)

      op?(token, @arithmetic) and not right_operand?(t, start) ->
        {"arithmetic is not supported", pos(token)}

      true ->
        in_group(t, w, i)
    end
  end

  # The innermost parenthesis still open says what was expected.
  defp in_group(t, w, i) do
    token = elem(t, i)

    case open_group(t, w, i) do
      nil ->
        end_of_statement(token)

      {_, :in_list} ->
        expected("')' to close the IN list", token)

      {_, :tuple} ->
        expected("')' to close the tuple", token)

      {_, :cast} ->
        expected("AS in CAST", token)

      {_, :cast_as} ->
        expected("')' to close CAST", token)

      {k, :paren} ->
        if op?(elem(t, k + 1), :*),
          do: {"'*' is only allowed in a tuple", pos(elem(t, k))},
          else: expected("')'", token)
    end
  end

  defp open_group(t, w, i) do
    Enum.reduce((w + 1)..(i - 1)//1, [], fn j, stack ->
      case {elem(t, j), stack} do
        {{:op, :"(", _}, _} ->
          kind =
            case elem(t, j - 1) do
              {:word, "in", _} -> :in_list
              {:word, "cast", _} -> :cast
              _ -> :paren
            end

          [{j, kind} | stack]

        {{:op, :")", _}, [_ | rest]} ->
          rest

        {{:op, :",", _}, [{k, :paren} | rest]} ->
          [{k, :tuple} | rest]

        {{:word, "as", _}, [{k, :cast} | rest]} ->
          [{k, :cast_as} | rest]

        _ ->
          stack
      end
    end)
    |> List.first()
  end

  defp in_cast?(t, w, i), do: match?({_, :cast}, open_group(t, w, i - 1))

  # -- the operand before an error --

  # Where the operand ending at `j` starts: step back over `::type` casts,
  # then over one primary.
  defp operand_start(t, j) do
    case type_start(t, j) do
      nil ->
        case elem(t, j) do
          {:op, :")", _} ->
            k = matching_open(t, j - 1, 0)
            if word?(elem(t, k - 1), "cast"), do: k - 1, else: k

          {type, _, _} when type in [:integer, :float] ->
            if op?(elem(t, j - 1), [:-, :+]) and operand_expected_after?(elem(t, j - 2)),
              do: j - 1,
              else: j

          _ ->
            j
        end

      k ->
        operand_start(t, k - 1)
    end
  end

  # If a `::type` ends at `j`, the index of its `::`.
  defp type_start(t, j) when j >= tuple_size(t), do: nil

  defp type_start(t, j) do
    cond do
      j >= 1 and op?(elem(t, j - 1), :"::") and match?({:word, _, _}, elem(t, j)) ->
        j - 1

      j >= 4 and op?(elem(t, j - 4), :"::") and word?(elem(t, j - 3), ~w[timestamp time]) and
        word?(elem(t, j - 2), ~w[with without]) and word?(elem(t, j - 1), "time") and
          word?(elem(t, j), "zone") ->
        j - 4

      true ->
        nil
    end
  end

  defp matching_open(t, j, depth) do
    case elem(t, j) do
      {:op, :")", _} -> matching_open(t, j - 1, depth + 1)
      {:op, :"(", _} when depth == 0 -> j
      {:op, :"(", _} -> matching_open(t, j - 1, depth - 1)
      _ -> matching_open(t, j - 1, depth)
    end
  end

  # The right-hand side of a comparison, LIKE or BETWEEN ... AND: the
  # operand the predicate ends with, so the error is the group's.
  defp right_operand?(t, start) do
    case elem(t, start - 1) do
      {:op, op, _} when op in @comparisons -> true
      {:word, like, _} when like in ~w[like ilike] -> true
      {:word, "and", _} -> between_and?(t, start - 1)
      _ -> false
    end
  end

  # An AND belongs to BETWEEN when the nearest boolean boundary before it
  # at the same depth is the BETWEEN.
  defp between_and?(t, j), do: between_and?(t, j - 1, 0)

  defp between_and?(t, j, depth) do
    case elem(t, j) do
      {:op, :")", _} -> between_and?(t, j - 1, depth + 1)
      {:op, :"(", _} when depth > 0 -> between_and?(t, j - 1, depth - 1)
      {:word, "between", _} when depth == 0 -> true
      {:word, word, _} when depth == 0 and word in ~w[and or where] -> false
      {:op, op, _} when depth == 0 and op in [:"(", :","] -> false
      _ -> between_and?(t, j - 1, depth)
    end
  end

  # A name standing as an expression, not a type name.
  defp name_primary?(t, j) do
    case elem(t, j) do
      {:quoted, _, _} -> true
      {:word, word, _} -> word not in @reserved and not type_position?(t, j)
      _ -> false
    end
  end

  # A word after `::` or CAST's AS, or inside `timestamp with time zone`.
  defp type_position?(t, j) do
    op?(elem(t, j - 1), :"::") or word?(elem(t, j - 1), "as") or type_start(t, j) != nil or
      (j >= 2 and word?(elem(t, j), ~w[with without time zone]) and
         (type_start(t, j + 1) != nil or type_start(t, j + 2) != nil or
            type_start(t, j + 3) != nil))
  end

  # `timestamp with` / `timestamp with time` cut short: the hand parser
  # takes the type as `timestamp` and stops at the `with`.
  defp half_type(t, i) do
    cond do
      i >= 3 and word?(elem(t, i - 1), ~w[with without]) and
        word?(elem(t, i - 2), ~w[timestamp time]) and
          type_opener?(elem(t, i - 3)) ->
        i - 1

      i >= 4 and word?(elem(t, i - 1), "time") and word?(elem(t, i - 2), ~w[with without]) and
        word?(elem(t, i - 3), ~w[timestamp time]) and type_opener?(elem(t, i - 4)) ->
        i - 2

      true ->
        nil
    end
  end

  defp type_opener?(token), do: op?(token, :"::") or word?(token, "as")

  # The last token of IN (...), IS [NOT] NULL, ISNULL or NOTNULL.
  defp ends_predicate?(t, j) do
    case elem(t, j) do
      {:op, :")", _} -> word?(elem(t, matching_open(t, j - 1, 0) - 1), "in")
      {:word, "null", _} -> word?(elem(t, j - 1), "is") or word?(elem(t, j - 2), "is")
      {:word, word, _} -> word in ~w[isnull notnull]
      _ -> false
    end
  end

  defp type_after_as?(t, j) do
    word?(elem(t, j - 1), "as") or
      (j >= 4 and word?(elem(t, j - 4), "as") and word?(elem(t, j - 3), ~w[timestamp time]) and
         word?(elem(t, j - 2), ~w[with without]) and word?(elem(t, j - 1), "time") and
         word?(elem(t, j), "zone"))
  end

  # Tokens after which an operand must come.
  defp operand_expected_after?(token) do
    word?(token, ~w[where and or not between like ilike]) or
      op?(token, [:"(", :"," | @comparisons])
  end

  # -- messages --

  defp end_of_statement({:word, word, pos}) when is_map_key(@unsupported_clauses, word),
    do: {"#{Map.fetch!(@unsupported_clauses, word)} is not supported", pos}

  defp end_of_statement({:op, op, pos}) when op in @arithmetic,
    do: {"arithmetic is not supported", pos}

  defp end_of_statement(token), do: expected("end of statement", token)

  defp nulls(pos), do: {"NULLS FIRST/LAST is not supported", pos}

  defp name_error({:word, word, pos}, what) when word in @reserved do
    {"expected #{what}, got the keyword '#{word}' (quote it, \"#{word}\", to use it as a name)",
     pos}
  end

  defp name_error(token, what), do: expected(what, token)

  defp expected(what, token), do: {"expected #{what}, got #{describe(token)}", pos(token)}

  defp describe({:word, word, _}), do: "'#{word}'"
  defp describe({:quoted, name, _}), do: inspect(name)
  defp describe({:string, s, _}), do: "the string '#{truncate(s)}'"
  defp describe({type, n, _}) when type in [:integer, :float], do: "the number #{n}"
  defp describe({:op, op, _}), do: "'#{op}'"
  defp describe({:eof, _, _}), do: "the end of the statement"

  defp truncate(s) do
    if String.length(s) > 20, do: String.slice(s, 0, 20) <> "...", else: s
  end

  defp pos({_, _, pos}), do: pos

  defp word?({:word, word, _}, words) when is_list(words), do: word in words
  defp word?({:word, word, _}, word), do: true
  defp word?(_, _), do: false

  defp op?({:op, op, _}, ops) when is_list(ops), do: op in ops
  defp op?({:op, op, _}, op), do: true
  defp op?(_, _), do: false
end
