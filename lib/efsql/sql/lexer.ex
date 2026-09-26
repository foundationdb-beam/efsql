defmodule Efsql.SQL.Lexer do
  @moduledoc """
  Turns SQL text into a list of tokens, ending with `{:eof, nil, position}`.

  A token is `{type, value, {line, column}}`, positioned at its first
  character:

    * `:word` — an unquoted identifier or keyword, folded to lower case as
      PostgreSQL does. Whether it is a keyword is up to the parser, so
      `day` or `user` can name a column.
    * `:quoted` — a `"double-quoted"` identifier, case kept; `""` is a
      literal quote.
    * `:string` — a `'single-quoted'` string; `''` is a literal quote.
    * `:integer` / `:float` — unsigned numbers: `42`, `1.5`, `.5`, `1e-3`.
    * `:op` — punctuation and operators, as atoms: `:=`, `:<>` (also
      written `!=`), `:<`, `:>`, `:<=`, `:>=`, `:"::"`, `:"("`, `:")"`,
      `:","`, `:.`, `:";"`, `:*`, `:+`, `:-`, `:/`, `:%`.

  Whitespace and comments (`-- to end of line`, and `/* ... */`, which
  nest) are dropped.
  """

  alias Efsql.SQL.SyntaxError

  @type position :: {pos_integer(), pos_integer()}
  @type token ::
          {:word | :quoted | :string, String.t(), position()}
          | {:integer, non_neg_integer(), position()}
          | {:float, float(), position()}
          | {:op, atom(), position()}
          | {:eof, nil, position()}

  @spec tokenize(String.t()) :: {:ok, [token()]} | {:error, SyntaxError.t()}
  def tokenize(sql) when is_binary(sql) do
    {:ok, lex(sql, 1, 1, [])}
  catch
    {:syntax_error, reason, {line, column}} ->
      {:error, %SyntaxError{reason: reason, line: line, column: column}}
  end

  @two_char_ops %{
    "<>" => :<>,
    "!=" => :<>,
    "<=" => :<=,
    ">=" => :>=,
    "::" => :"::"
  }

  @one_char_ops %{
    ?= => :=,
    ?< => :<,
    ?> => :>,
    ?( => :"(",
    ?) => :")",
    ?, => :",",
    ?. => :.,
    ?; => :";",
    ?* => :*,
    ?+ => :+,
    ?- => :-,
    ?/ => :/,
    ?% => :%
  }

  defp lex(<<>>, line, col, acc), do: Enum.reverse([{:eof, nil, {line, col}} | acc])

  # newlines: \r\n, \n and a lone \r each end a line
  defp lex(<<?\r, ?\n, rest::binary>>, line, _col, acc), do: lex(rest, line + 1, 1, acc)

  defp lex(<<c, rest::binary>>, line, _col, acc) when c in [?\n, ?\r],
    do: lex(rest, line + 1, 1, acc)

  defp lex(<<c, rest::binary>>, line, col, acc) when c in [?\s, ?\t, ?\f, ?\v],
    do: lex(rest, line, col + 1, acc)

  defp lex(<<"--", rest::binary>>, line, col, acc), do: line_comment(rest, line, col + 2, acc)

  defp lex(<<"/*", rest::binary>>, line, col, acc),
    do: block_comment(rest, line, col + 2, 1, {line, col}, acc)

  defp lex(<<?', rest::binary>>, line, col, acc) do
    {value, rest, line2, col2} = quoted(rest, ?', line, col + 1, [], {line, col}, "string")
    lex(rest, line2, col2, [{:string, value, {line, col}} | acc])
  end

  defp lex(<<?", rest::binary>>, line, col, acc) do
    {value, rest, line2, col2} = quoted(rest, ?", line, col + 1, [], {line, col}, "identifier")

    if value == "" do
      throw({:syntax_error, "zero-length quoted identifier", {line, col}})
    end

    lex(rest, line2, col2, [{:quoted, value, {line, col}} | acc])
  end

  defp lex(<<c, _::binary>> = sql, line, col, acc) when c in ?0..?9,
    do: number(sql, line, col, acc)

  defp lex(<<?., c, _::binary>> = sql, line, col, acc) when c in ?0..?9,
    do: number(sql, line, col, acc)

  defp lex(<<a, b, rest::binary>>, line, col, acc)
       when is_map_key(@two_char_ops, <<a, b>>) do
    lex(rest, line, col + 2, [{:op, Map.fetch!(@two_char_ops, <<a, b>>), {line, col}} | acc])
  end

  defp lex(<<?:, c::utf8, _::binary>>, line, col, _acc) do
    if word_start?(c) do
      throw(
        {:syntax_error, "unexpected ':' (write an atom as a cast, e.g. 'name'::atom)",
         {line, col}}
      )
    else
      throw({:syntax_error, "unexpected ':'", {line, col}})
    end
  end

  defp lex(<<c, rest::binary>>, line, col, acc) when is_map_key(@one_char_ops, c) do
    lex(rest, line, col + 1, [{:op, Map.fetch!(@one_char_ops, c), {line, col}} | acc])
  end

  defp lex(<<c::utf8, rest::binary>> = sql, line, col, acc) do
    cond do
      word_start?(c) ->
        {raw, rest, length} = take_word(sql, [], 0)
        lex(rest, line, col + length, [{:word, String.downcase(raw), {line, col}} | acc])

      unicode_space?(c) ->
        lex(rest, line, col + 1, acc)

      true ->
        throw({:syntax_error, "unexpected character #{inspect(<<c::utf8>>)}", {line, col}})
    end
  end

  defp lex(<<byte, _::binary>>, line, col, _acc) do
    throw({:syntax_error, "invalid UTF-8 byte 0x#{Integer.to_string(byte, 16)}", {line, col}})
  end

  # -- comments --

  defp line_comment(<<>>, line, col, acc), do: lex(<<>>, line, col, acc)
  defp line_comment(<<?\r, ?\n, rest::binary>>, line, _col, acc), do: lex(rest, line + 1, 1, acc)

  defp line_comment(<<c, rest::binary>>, line, _col, acc) when c in [?\n, ?\r],
    do: lex(rest, line + 1, 1, acc)

  defp line_comment(<<_::utf8, rest::binary>>, line, col, acc),
    do: line_comment(rest, line, col + 1, acc)

  defp line_comment(<<_, rest::binary>>, line, col, acc),
    do: line_comment(rest, line, col + 1, acc)

  defp block_comment(<<>>, _line, _col, _depth, start, _acc),
    do: throw({:syntax_error, "unterminated /* comment", start})

  defp block_comment(<<"*/", rest::binary>>, line, col, 1, _start, acc),
    do: lex(rest, line, col + 2, acc)

  defp block_comment(<<"*/", rest::binary>>, line, col, depth, start, acc),
    do: block_comment(rest, line, col + 2, depth - 1, start, acc)

  defp block_comment(<<"/*", rest::binary>>, line, col, depth, start, acc),
    do: block_comment(rest, line, col + 2, depth + 1, start, acc)

  defp block_comment(<<?\r, ?\n, rest::binary>>, line, _col, depth, start, acc),
    do: block_comment(rest, line + 1, 1, depth, start, acc)

  defp block_comment(<<c, rest::binary>>, line, _col, depth, start, acc) when c in [?\n, ?\r],
    do: block_comment(rest, line + 1, 1, depth, start, acc)

  defp block_comment(<<_::utf8, rest::binary>>, line, col, depth, start, acc),
    do: block_comment(rest, line, col + 1, depth, start, acc)

  defp block_comment(<<_, rest::binary>>, line, col, depth, start, acc),
    do: block_comment(rest, line, col + 1, depth, start, acc)

  # -- quoted strings and identifiers --

  # A doubled quote is a literal quote; anything else, newlines included,
  # is taken verbatim.
  defp quoted(<<>>, q, _line, _col, _acc, start, what) do
    throw({:syntax_error, "unterminated #{what} (missing closing #{<<q>>})", start})
  end

  defp quoted(<<q, q, rest::binary>>, q, line, col, acc, start, what),
    do: quoted(rest, q, line, col + 2, [q | acc], start, what)

  defp quoted(<<q, rest::binary>>, q, line, col, acc, _start, _what),
    do: {acc |> Enum.reverse() |> List.to_string(), rest, line, col + 1}

  defp quoted(<<?\r, ?\n, rest::binary>>, q, line, _col, acc, start, what),
    do: quoted(rest, q, line + 1, 1, [?\n, ?\r | acc], start, what)

  defp quoted(<<c, rest::binary>>, q, line, _col, acc, start, what) when c in [?\n, ?\r],
    do: quoted(rest, q, line + 1, 1, [c | acc], start, what)

  defp quoted(<<c::utf8, rest::binary>>, q, line, col, acc, start, what),
    do: quoted(rest, q, line, col + 1, [c | acc], start, what)

  defp quoted(<<byte, _::binary>>, _q, line, col, _acc, _start, _what) do
    throw({:syntax_error, "invalid UTF-8 byte 0x#{Integer.to_string(byte, 16)}", {line, col}})
  end

  # -- numbers --

  defp number(sql, line, col, acc) do
    {int, rest} = digits(sql, [])
    {frac, rest} = fraction(rest)
    {exp, rest} = exponent(rest, line, col)
    text = int <> frac <> exp
    length = String.length(text)

    case rest do
      <<c::utf8, _::binary>> ->
        if word_start?(c) or c in ?0..?9 or c == ?. do
          throw({:syntax_error, "invalid number #{inspect(text <> <<c::utf8>>)}", {line, col}})
        end

      _ ->
        :ok
    end

    token =
      if frac == "" and exp == "" do
        {:integer, String.to_integer(int), {line, col}}
      else
        int = if int == "", do: "0", else: int
        frac = if frac in ["", "."], do: ".0", else: frac
        {:float, to_float(int <> frac <> exp, text, {line, col}), {line, col}}
      end

    lex(rest, line, col + length, [token | acc])
  end

  # Beyond a double's range, e.g. 1e400.
  defp to_float(normalized, text, pos) do
    String.to_float(normalized)
  rescue
    ArgumentError -> throw({:syntax_error, "number out of range: #{text}", pos})
  end

  defp digits(<<c, rest::binary>>, acc) when c in ?0..?9, do: digits(rest, [c | acc])
  defp digits(rest, acc), do: {acc |> Enum.reverse() |> List.to_string(), rest}

  defp fraction(<<?., rest::binary>>) do
    {frac, rest} = digits(rest, [])
    {"." <> frac, rest}
  end

  defp fraction(rest), do: {"", rest}

  defp exponent(<<e, sign, rest::binary>>, line, col) when e in [?e, ?E] and sign in [?+, ?-] do
    exponent_digits(<<e, sign>>, rest, line, col)
  end

  defp exponent(<<e, rest::binary>>, line, col) when e in [?e, ?E] do
    exponent_digits(<<e>>, rest, line, col)
  end

  defp exponent(rest, _line, _col), do: {"", rest}

  defp exponent_digits(prefix, rest, line, col) do
    case digits(rest, []) do
      {"", _} -> throw({:syntax_error, "invalid number: exponent has no digits", {line, col}})
      {exp, rest} -> {prefix <> exp, rest}
    end
  end

  # -- words --

  defp take_word(<<c::utf8, rest::binary>> = sql, acc, length) do
    if word_continue?(c) do
      take_word(rest, [c | acc], length + 1)
    else
      {acc |> Enum.reverse() |> List.to_string(), sql, length}
    end
  end

  defp take_word(rest, acc, length), do: {acc |> Enum.reverse() |> List.to_string(), rest, length}

  defp word_start?(c) when c in ?a..?z or c in ?A..?Z or c == ?_, do: true
  defp word_start?(c) when c < 128, do: false
  defp word_start?(c), do: String.match?(<<c::utf8>>, ~r/^\p{L}$/u)

  defp word_continue?(c) when c in ?0..?9 or c == ?$, do: true
  defp word_continue?(c) when c < 128, do: word_start?(c)
  defp word_continue?(c), do: String.match?(<<c::utf8>>, ~r/^[\p{L}\p{M}\p{N}]$/u)

  # NBSP, the Unicode spaces, and a byte-order mark
  defp unicode_space?(c),
    do: c in [0xA0, 0x1680, 0x202F, 0x205F, 0x3000, 0xFEFF] or c in 0x2000..0x200A
end
