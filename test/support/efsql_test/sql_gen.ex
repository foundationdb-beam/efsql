defmodule EfsqlTest.SQLGen do
  @moduledoc false
  # Random `Efsql.SQL.AST.Select` trees, and a printer that renders one as
  # SQL text with randomized spelling: keyword case, whitespace and
  # comments between tokens, optional quoting, `!=` for `<>`, `CAST(...)`
  # for `::`, `ISNULL` for `IS NULL`. Parsing the text must give back the
  # tree. Uses `:rand`, which ExUnit seeds per test from `--seed`.

  alias Efsql.SQL.AST.Select

  # Names that print unquoted. None is reserved, and each survives
  # upcasing and folding back down unchanged.
  @plain_names ~w[a b id name status day at user value date time zone created_at _ x1 a$b café 日本語]
  @types ~w[atom timestamp timestamptz date time widget]
  @name_chars String.graphemes("abcXYZ019 _-.,;'\"()*é日\n") ++ ["select", "FROM", "--", "/*"]
  @string_chars String.graphemes("abc XYZ 019_-.,;:'\"()*%é☃\n\t") ++ ["--", "/*", "*/", "''"]

  def select() do
    %Select{
      fields: if(one_in(4), do: :star, else: list(1..4, &name/0)),
      from: list(1..3, &name/0),
      where: maybe(fn -> expr(3) end),
      order_by: list(0..3, fn -> {name(), Enum.random([:asc, :desc])} end),
      limit: maybe(fn -> Enum.random([0, 1, 15, 1000, 123_456_789]) end)
    }
  end

  # -- trees --

  def expr(0), do: predicate()

  def expr(depth) do
    case Enum.random(1..6) do
      1 -> {:and, expr(depth - 1), expr(depth - 1)}
      2 -> {:or, expr(depth - 1), expr(depth - 1)}
      3 -> {:not, expr(depth - 1)}
      _ -> predicate()
    end
  end

  def predicate() do
    case Enum.random(1..8) do
      1 -> {:between, operand(2), operand(2), operand(2), bool()}
      2 -> {:in, operand(2), list(1..4, fn -> operand(2) end), bool()}
      3 -> {Enum.random([:like, :ilike]), operand(2), operand(2), bool()}
      4 -> {:is_null, operand(2), bool()}
      5 -> operand(2)
      _ -> {:compare, Enum.random([:=, :<>, :<, :>, :<=, :>=]), operand(2), operand(2)}
    end
  end

  def operand(depth) do
    case Enum.random(1..7) do
      1 when depth > 0 -> {:cast, operand(depth - 1), Enum.random(@types)}
      2 -> tuple()
      n when n in 3..4 -> {:column, name()}
      _ -> literal()
    end
  end

  defp tuple() do
    {:tuple, list(2..3, fn -> if one_in(3), do: :star, else: literal() end)}
  end

  def literal() do
    value =
      case Enum.random(1..7) do
        1 -> Enum.random(-1000..1000)
        2 -> Enum.random([0, 22_348_699_227_647_901_699, 12_345_678_901_234_567_890_123])
        3 -> Float.round((:rand.uniform() - 0.5) * 2000, Enum.random(0..6)) + 0.5
        4 -> Enum.random([true, false, nil])
        _ -> random_string(@string_chars, 0..8)
      end

    {:literal, value}
  end

  def name() do
    if one_in(4),
      do: random_string(@name_chars, 1..6),
      else: Enum.random(@plain_names)
  end

  # -- printing --

  def to_sql(%Select{} = select) do
    [
      kw("select"),
      fields(select.fields),
      kw("from"),
      Enum.intersperse(Enum.map(select.from, &print_name/1), p(".")),
      if(select.where, do: [kw("where"), print(select.where)], else: []),
      order_by(select.order_by),
      if(select.limit, do: [kw("limit"), w(Integer.to_string(select.limit))], else: []),
      if(one_in(2), do: [p(";")], else: [])
    ]
    |> List.flatten()
    |> join()
  end

  defp fields(:star), do: [p("*")]
  defp fields(names), do: comma(Enum.map(names, &print_name/1))

  defp order_by([]), do: []

  defp order_by(items) do
    [
      kw("order"),
      kw("by"),
      comma(
        Enum.map(items, fn
          {name, :asc} -> [print_name(name) | Enum.random([[], [kw("asc")]])]
          {name, :desc} -> [print_name(name), kw("desc")]
        end)
      )
    ]
  end

  # Boolean operators always get parentheses, so the printed nesting is
  # exactly the tree's whatever the precedence.
  defp print({op, l, r}) when op in [:and, :or],
    do: [p("("), print(l), kw(Atom.to_string(op)), print(r), p(")")]

  defp print({:not, e}), do: [kw("not"), p("("), print(e), p(")")]

  defp print({:compare, op, l, r}) do
    op = if op == :<>, do: Enum.random(["<>", "!="]), else: Atom.to_string(op)
    [print(l), p(op), print(r)]
  end

  defp print({:between, e, low, high, negated?}),
    do: [print(e), negated(negated?), kw("between"), print(low), kw("and"), print(high)]

  defp print({:in, e, values, negated?}),
    do: [print(e), negated(negated?), kw("in"), p("("), comma(Enum.map(values, &print/1)), p(")")]

  defp print({like, e, pattern, negated?}) when like in [:like, :ilike],
    do: [print(e), negated(negated?), kw(Atom.to_string(like)), print(pattern)]

  defp print({:is_null, e, negated?}) do
    case {negated?, one_in(3)} do
      {false, true} -> [print(e), kw("isnull")]
      {true, true} -> [print(e), kw("notnull")]
      _ -> [print(e), kw("is"), negated(negated?), kw("null")]
    end
  end

  defp print({:column, name}), do: print_name(name)

  defp print({:cast, e, type}) do
    if one_in(3),
      do: [kw("cast"), p("("), print(e), kw("as"), type(type), p(")")],
      else: [print(e), p("::"), type(type)]
  end

  defp print({:tuple, elements}) do
    [
      p("("),
      comma(
        Enum.map(elements, fn
          :star -> p("*")
          e -> print(e)
        end)
      ),
      p(")")
    ]
  end

  defp print({:literal, nil}), do: kw("null")
  defp print({:literal, b}) when is_boolean(b), do: kw(Atom.to_string(b))
  defp print({:literal, n}) when is_integer(n), do: w(Integer.to_string(n))
  defp print({:literal, f}) when is_float(f), do: w(Float.to_string(f))
  defp print({:literal, s}) when is_binary(s), do: w("'" <> String.replace(s, "'", "''") <> "'")

  defp type("timestamptz") do
    if one_in(2),
      do: w("timestamptz"),
      else: [kw("timestamp"), kw("with"), kw("time"), kw("zone")]
  end

  defp type(type), do: kw(type)

  defp negated(true), do: [kw("not")]
  defp negated(false), do: []

  defp print_name(name) do
    if name in @plain_names and not one_in(5),
      do: w(random_case(name)),
      else: w(~s(") <> String.replace(name, ~s("), ~s("")) <> ~s("))
  end

  defp comma(items), do: Enum.intersperse(items, p(","))

  # A token is {:w, text} (needs a separator from its neighbours) or
  # {:p, text} (punctuation, which may touch them).
  defp kw(text), do: {:w, random_case(text)}
  defp w(text), do: {:w, text}
  defp p(text), do: {:p, text}

  @separators [
    " ",
    "  ",
    "\n",
    "\t",
    "\r\n",
    " ",
    " -- note ; 'x' \"y\"\n",
    " /* a /* b */ c */ "
  ]

  defp join(tokens) do
    tokens
    |> Enum.chunk_every(2, 1)
    |> Enum.map_join(fn
      [{_, text}] -> text
      [{:w, text}, {:w, _}] -> text <> Enum.random(@separators)
      [{_, text}, _] -> text <> Enum.random(["" | @separators])
    end)
  end

  defp random_case(text) do
    case Enum.random(1..3) do
      1 -> String.upcase(text)
      2 -> String.capitalize(text)
      3 -> text
    end
  end

  # -- broken input --

  @junk [
    "(",
    ")",
    "'",
    "\"",
    ",",
    ";",
    "-",
    "+",
    "*",
    ":",
    "::",
    ".",
    "=",
    "<",
    "not",
    " and ",
    " or ",
    " is ",
    " in ",
    " between ",
    "é",
    <<0xC3>>,
    " select ",
    " x ",
    "1",
    " -- c\n",
    "/*",
    "*/",
    " timestamp ",
    " with ",
    " time ",
    " zone ",
    " cast ",
    " as ",
    " order ",
    " by ",
    " limit ",
    " desc ",
    " nulls "
  ]

  @doc "`n` random edits to `sql`: deletes, inserts, replacements, duplications, truncation."
  def mangle(sql, 0), do: sql

  def mangle(sql, n) do
    chars = String.graphemes(sql)
    at = Enum.random(0..length(chars))
    junk = Enum.random(@junk)

    chars =
      case Enum.random(1..5) do
        1 -> List.delete_at(chars, at)
        2 -> List.insert_at(chars, at, junk)
        3 -> List.replace_at(chars, at, junk)
        4 -> Enum.take(chars, at) ++ Enum.slice(chars, at, 10) ++ Enum.drop(chars, at)
        5 -> Enum.take(chars, at)
      end

    mangle(Enum.join(chars), n - 1)
  end

  @alphabet String.graphemes("selctfromwhandi*,.;()'\"=<>!:-+/%_ \n\t0123456789eé") ++
              ["select ", " from ", " where ", " and ", "--", "/*", "*/", "::", <<0xFF>>, <<0>>]

  @doc "Up to 40 random SQL-ish fragments and bytes, invalid UTF-8 included."
  def garbage(), do: random_string(@alphabet, 0..40)

  # -- helpers --

  defp random_string(pool, range) do
    Enum.map_join(1..Enum.random(range)//1, fn _ -> Enum.random(pool) end)
  end

  defp list(range, fun), do: Enum.map(1..Enum.random(range)//1, fn _ -> fun.() end)
  defp maybe(fun), do: if(one_in(2), do: fun.(), else: nil)
  defp bool(), do: one_in(2)
  defp one_in(n), do: :rand.uniform(n) == 1
end
