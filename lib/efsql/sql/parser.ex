defmodule Efsql.SQL.Parser do
  @moduledoc """
  Parses one `SELECT` statement into an `Efsql.SQL.AST.Select`.

      SELECT items FROM name [WHERE expr] [GROUP BY names] [ORDER BY items]
        [LIMIT n] [;]

  An item is a name or an aggregate call, `count(*)` or `sum(price)`,
  optionally named with `AS alias`.

  The grammar is `src/efsql_sql_grammar.yrl`, compiled by yecc; this
  module feeds it `Efsql.SQL.Lexer` tokens and explains its errors.

  The reserved words below can't be bare names, because a name could be
  mistaken for them; quote them to use them as names (`"order"`).
  Everything else (`day`, `user`, `date`, `value`, ...) is an ordinary
  name, and any word, reserved or not, can be a type (`'x'::date`).

  Precedence, loosest first: `OR`, `AND`, `NOT`, then a predicate
  (comparison, `BETWEEN`, `IN`, `LIKE`, `IS NULL`), then `::` casts.

  ## Errors

  yecc only reports the token it stopped at. To say what it wanted
  instead, the parser replays the tokens before it with each terminal in
  turn and keeps those the grammar accepts, so messages follow the
  grammar with no upkeep: `expected BY, got the end of the statement`.
  A few hints on top name features that aren't supported yet, such as
  `HAVING` or joins; drop a hint when its feature lands.
  """

  alias Efsql.SQL.AST
  alias Efsql.SQL.Lexer
  alias Efsql.SQL.SyntaxError

  # These must match the grammar's keyword Terminals.
  @reserved ~w[all and as asc between by case cast cross desc distinct else end except
               false from full group having ilike in inner intersect is isnull join
               left like limit not notnull null offset on or order right select then
               true union when where with]

  # Keywords that are also names.
  @soft ~w[time timestamp without zone]

  @keywords @reserved ++ @soft
  @ops [:=, :<>, :<, :>, :<=, :>=, :"::", :"(", :")", :",", :., :";", :*, :+, :-]

  # Every terminal of the grammar, plus the end of input: the candidates
  # for "what could have come next".
  @terminals [:ident, :quoted, :string, :integer, :float] ++
               Enum.map(@keywords, &String.to_atom/1) ++ @ops ++ [:"$end"]

  @name_starts [:ident, :quoted | Enum.map(@soft, &String.to_atom/1)]
  @expression_starts @name_starts ++
                       [:string, :integer, :float, :cast, true, false, :null, :"(", :+, :-]
  @comparisons [:=, :<>, :<, :>, :<=, :>=]
  @operators @comparisons ++
               [:and, :or, :not, :between, :in, :like, :ilike, :is, :isnull, :notnull, :"::"]

  @not_select ~w[insert update delete create drop alter truncate grant revoke explain]
  @unsupported %{
    "distinct" => "DISTINCT",
    "having" => "HAVING",
    "offset" => "OFFSET",
    "join" => "JOIN",
    "inner" => "JOIN",
    "left" => "JOIN",
    "right" => "JOIN",
    "full" => "JOIN",
    "cross" => "JOIN",
    "union" => "UNION",
    "with" => "WITH",
    "intersect" => "INTERSECT",
    "except" => "EXCEPT",
    "fetch" => "FETCH"
  }

  @functions_only_aggregates "functions are only supported as aggregates, " <>
                               "in the select list and ORDER BY"

  def reserved_words, do: @reserved

  @spec parse(String.t()) :: {:ok, AST.Select.t()} | {:error, SyntaxError.t()}
  def parse(sql) when is_binary(sql) do
    with {:ok, tokens} <- Lexer.tokenize(sql) do
      grammar_tokens = tokens |> Enum.with_index() |> Enum.map(&to_grammar/1)

      case :efsql_sql_grammar.parse(grammar_tokens) do
        {:ok, {:select, fields, from, where, group_by, order_by, limit}} ->
          {:ok,
           %AST.Select{
             fields: fields,
             from: from,
             where: where,
             group_by: group_by,
             order_by: order_by,
             limit: limit
           }}

        {:error, {at, :efsql_sql_grammar, _}} ->
          tokens = List.to_tuple(tokens)
          {_, _, {line, column}} = elem(tokens, at)
          reason = explain(tokens, at, expected(grammar_tokens, at))
          {:error, %SyntaxError{reason: reason, line: line, column: column}}
      end
    end
  end

  @spec parse!(String.t()) :: AST.Select.t()
  def parse!(sql) do
    case parse(sql) do
      {:ok, select} -> select
      {:error, error} -> raise error
    end
  end

  defp to_grammar({{:word, word, _}, i}) when word in @keywords,
    do: {String.to_atom(word), i, word}

  defp to_grammar({{:word, word, _}, i}), do: {:ident, i, word}
  defp to_grammar({{:op, op, _}, i}), do: {op, i, op}
  defp to_grammar({{:eof, nil, _}, i}), do: {:"$end", i}
  defp to_grammar({{type, value, _}, i}), do: {type, i, value}

  # -- errors --

  # The terminals the grammar accepts after the first `at` tokens. An LR
  # parser never shifts a token it can't use, so a candidate is refused
  # exactly when the parse fails at the candidate itself.
  defp expected(grammar_tokens, at) do
    prefix = Enum.take(grammar_tokens, at)

    for terminal <- @terminals, accepts?(prefix, at, terminal), into: MapSet.new() do
      terminal
    end
  end

  defp accepts?(prefix, at, :"$end"), do: accepts?(prefix ++ [{:"$end", at}], at)

  defp accepts?(prefix, at, terminal),
    do: accepts?(prefix ++ [{terminal, at, sample(terminal)}, {:"$end", at + 1}], at)

  defp accepts?(tokens, at),
    do: not match?({:error, {^at, _, _}}, :efsql_sql_grammar.parse(tokens))

  defp sample(:integer), do: 1
  defp sample(:float), do: 1.0
  defp sample(terminal) when terminal in [:ident, :quoted, :string], do: "x"
  defp sample(terminal) when is_atom(terminal), do: Atom.to_string(terminal)

  defp explain(tokens, at, expected) do
    token = elem(tokens, at)
    previous = if at > 0, do: elem(tokens, at - 1)

    table_part_limit(tokens, at) || hint(token, previous, at, expected) ||
      "expected #{describe_expected(expected)}, got #{describe(token)}"
  end

  # Only a table name has parts (storage_id.tenant.table), so a dot after
  # a two-dot name is one part too many.
  defp table_part_limit(tokens, at) do
    if at >= 4 and match?({:op, :., _}, elem(tokens, at)) and
         match?({:op, :., _}, elem(tokens, at - 2)) and
         match?({:op, :., _}, elem(tokens, at - 4)),
       do: "a table name has at most three parts (storage_id.tenant.table)"
  end

  # Hints for what the grammar doesn't cover yet, and one for reserved
  # words used as names.
  defp hint({:eof, _, _}, nil, 0, _), do: "empty statement"

  defp hint({:word, word, _}, nil, 0, _) when word in @not_select,
    do: "only SELECT statements are supported"

  defp hint(_, {:op, :";", _}, _, _), do: "only one statement is supported"

  defp hint({:word, "select", _}, {:op, :"(", _}, _, _), do: "subqueries are not supported"

  defp hint({:word, word, _}, _, _, expected) when word in @reserved do
    cond do
      word == "distinct" ->
        "DISTINCT is not supported"

      MapSet.member?(expected, :ident) ->
        "expected #{describe_expected(expected)}, got the keyword '#{word}' " <>
          "(quote it, \"#{word}\", to use it as a name)"

      Map.has_key?(@unsupported, word) ->
        "#{@unsupported[word]} is not supported"

      true ->
        nil
    end
  end

  defp hint({:word, "fetch", _}, _, _, _), do: "FETCH is not supported"

  defp hint({:op, :"(", _}, {:word, word, _}, _, _) when word not in @keywords,
    do: @functions_only_aggregates

  defp hint({:op, :"(", _}, {:quoted, _, _}, _, _), do: @functions_only_aggregates

  defp hint({:op, :., _}, {type, _, _}, _, _) when type in [:word, :quoted],
    do: "qualified column names are not supported"

  defp hint({:op, op, _}, previous, _, _)
       when op in [:+, :-, :*, :/, :%] and previous != nil do
    if ends_operand?(previous), do: "arithmetic is not supported"
  end

  defp hint(_, {:op, sign, _}, _, expected) when sign in [:+, :-] do
    if MapSet.member?(expected, :integer), do: "a sign is only supported on a number"
  end

  defp hint(_, _, _, _), do: nil

  defp ends_operand?({:word, word, _}), do: word not in @reserved

  defp ends_operand?({type, _, _}) when type in [:quoted, :string, :integer, :float],
    do: true

  defp ends_operand?({:op, :")", _}), do: true
  defp ends_operand?(_), do: false

  # Collapses the accepted terminals into a few words: "an expression",
  # "a name", "an operator", "a type name", then any keywords and symbols.
  defp describe_expected(expected) do
    cond do
      MapSet.member?(expected, :"$end") ->
        "the end of the statement"

      MapSet.member?(expected, :from) and MapSet.member?(expected, :ident) ->
        "a type name"

      true ->
        {groups, rest} =
          Enum.reduce(
            [
              {"an expression", @expression_starts ++ [:not]},
              {"a name", @name_starts},
              {"an operator", @operators}
            ],
            {[], expected},
            fn {label, members}, {groups, rest} ->
              if group_present?(label, members, rest),
                do: {[label | groups], MapSet.difference(rest, MapSet.new(members))},
                else: {groups, rest}
            end
          )

        (Enum.reverse(groups) ++ Enum.map(Enum.filter(@terminals, &(&1 in rest)), &terminal/1))
        |> join_or()
    end
  end

  defp group_present?("an operator", _members, rest),
    do: Enum.all?(@comparisons, &MapSet.member?(rest, &1))

  defp group_present?(_label, members, rest),
    do: Enum.all?(members -- [:not], &MapSet.member?(rest, &1))

  defp terminal(:integer), do: "a whole number"
  defp terminal(:float), do: "a number"
  defp terminal(:string), do: "a string"
  defp terminal(:ident), do: "a name"
  defp terminal(:quoted), do: "a quoted name"
  defp terminal(op) when op in @ops, do: "'#{op}'"
  defp terminal(keyword), do: keyword |> Atom.to_string() |> String.upcase()

  defp join_or([one]), do: one
  defp join_or(items), do: Enum.join(Enum.drop(items, -1), ", ") <> " or " <> List.last(items)

  defp describe({:word, word, _}), do: "'#{word}'"
  defp describe({:quoted, name, _}), do: inspect(name)
  defp describe({:string, s, _}), do: "the string '#{truncate(s)}'"
  defp describe({type, n, _}) when type in [:integer, :float], do: "the number #{n}"
  defp describe({:op, op, _}), do: "'#{op}'"
  defp describe({:eof, _, _}), do: "the end of the statement"

  defp truncate(s) do
    if String.length(s) > 20, do: String.slice(s, 0, 20) <> "...", else: s
  end
end
