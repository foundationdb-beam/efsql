defmodule Efsql.SQL.Leex do
  @moduledoc """
  The same contract as `Efsql.SQL.Lexer.tokenize/1`, built on the leex
  tokenizer in `src/efsql_sql_leex.xrl`.

  leex matches the token shapes. This driver pulls one match at a time
  (`token/2`) and does what the rules can't: it tracks positions in
  characters (leex counts UTF-8 bytes), skips nested block comments,
  applies the Unicode letter classes, and turns the raw matches into
  tokens and errors.
  """

  alias Efsql.SQL.SyntaxError

  # Invalid UTF-8 bytes are passed to leex as integers above U+10FFFF.
  @bad_byte 0x110000

  @ops %{
    ~c"<>" => :<>,
    ~c"!=" => :<>,
    ~c"<=" => :<=,
    ~c">=" => :>=,
    ~c"::" => :"::",
    ~c"=" => :=,
    ~c"<" => :<,
    ~c">" => :>,
    ~c"(" => :"(",
    ~c")" => :")",
    ~c"," => :",",
    ~c"." => :.,
    ~c";" => :";",
    ~c"*" => :*,
    ~c"+" => :+,
    ~c"-" => :-,
    ~c"/" => :/,
    ~c"%" => :%
  }

  @spec tokenize(String.t()) :: {:ok, [Efsql.SQL.Lexer.token()]} | {:error, SyntaxError.t()}
  def tokenize(sql) when is_binary(sql) do
    {:ok, lex(decode(sql, []), 1, 1, [])}
  catch
    {:syntax_error, reason, {line, column}} ->
      {:error, %SyntaxError{reason: reason, line: line, column: column}}
  end

  defp decode(<<c::utf8, rest::binary>>, acc), do: decode(rest, [c | acc])
  defp decode(<<byte, rest::binary>>, acc), do: decode(rest, [@bad_byte + byte | acc])
  defp decode(<<>>, acc), do: Enum.reverse(acc)

  defp lex([], line, col, acc), do: Enum.reverse([{:eof, nil, {line, col}} | acc])

  defp lex(chars, line, col, acc) do
    case next(chars) do
      {{:ok, {kind, matched}, _}, rest} -> token(kind, matched, rest, {line, col}, acc)
      {{:error, _, _}, _} -> illegal(hd(chars), {line, col})
    end
  end

  defp next(chars) do
    case :efsql_sql_leex.token([], chars) do
      {:done, result, rest} ->
        {result, rest(rest)}

      {:more, cont} ->
        cont |> :efsql_sql_leex.token(:eof) |> then(fn {:done, r, rest} -> {r, rest(rest)} end)
    end
  end

  defp rest(:eof), do: []
  defp rest(chars), do: chars

  defp token(:ws, matched, rest, pos, acc), do: continue(matched, rest, pos, acc)

  # A line comment runs to the end of the line, whatever it holds.
  defp token(:line_comment, matched, rest, pos, acc) do
    {comment, rest} = Enum.split_while(rest, &(&1 not in [?\n, ?\r]))
    continue(matched ++ comment, rest, pos, acc)
  end

  defp token(:block_comment, _matched, rest, {line, col} = start, acc) do
    {rest, line, col} = block_comment(rest, line, col + 2, 1, start)
    lex(rest, line, col, acc)
  end

  defp token(kind, matched, rest, pos, acc) when kind in [:string, :quoted] do
    check_bytes(matched, pos)
    value = matched |> Enum.slice(1..-2//1) |> List.to_string()

    {type, value} =
      case kind do
        :string ->
          {:string, String.replace(value, "''", "'")}

        :quoted ->
          if value == "", do: error("zero-length quoted identifier", pos)
          {:quoted, String.replace(value, ~s(""), ~s("))}
      end

    continue(matched, rest, pos, [{type, value, pos} | acc])
  end

  defp token(:unterminated, [quote | _] = matched, _rest, pos, _acc) do
    check_bytes(matched, pos)
    what = if quote == ?', do: "string", else: "identifier"
    error("unterminated #{what} (missing closing #{<<quote>>})", pos)
  end

  defp token(:number, matched, rest, pos, acc) do
    continue(matched, rest, pos, [number(List.to_string(matched), pos) | acc])
  end

  defp token(:bad_exponent, _matched, _rest, pos, _acc),
    do: error("invalid number: exponent has no digits", pos)

  # A number run into another character is an error when that character
  # could continue it; otherwise the number ends and the character is
  # lexed on its own.
  defp token(:number_junk, matched, rest, pos, acc) do
    {number, [c]} = Enum.split(matched, -1)

    if word_start?(c) or c == ?. do
      error("invalid number #{inspect(List.to_string(matched))}", pos)
    end

    continue(number, [c | rest], pos, [number(List.to_string(number), pos) | acc])
  end

  # leex matches any run of letters and non-ASCII characters; the word is
  # the part the Unicode classes allow, and the rest is lexed again.
  defp token(:word, [c | tail] = matched, rest, pos, acc) do
    cond do
      word_start?(c) ->
        {word, leftover} = Enum.split_while(matched, &word_continue?/1)
        value = word |> List.to_string() |> String.downcase()
        continue(word, leftover ++ rest, pos, [{:word, value, pos} | acc])

      unicode_space?(c) ->
        continue([c], tail ++ rest, pos, acc)

      true ->
        illegal(c, pos)
    end
  end

  defp token(:op, matched, rest, pos, acc),
    do: continue(matched, rest, pos, [{:op, Map.fetch!(@ops, matched), pos} | acc])

  defp token(:colon, [?:, c], _rest, pos, _acc) do
    if word_start?(c),
      do: error("unexpected ':' (write an atom as a cast, e.g. 'name'::atom)", pos),
      else: error("unexpected ':'", pos)
  end

  defp token(:colon, [?:], _rest, pos, _acc), do: illegal(?:, pos)

  defp continue(consumed, rest, {line, col}, acc) do
    {line, col} = advance(consumed, line, col)
    lex(rest, line, col, acc)
  end

  defp advance([?\r, ?\n | rest], line, _col), do: advance(rest, line + 1, 1)
  defp advance([c | rest], line, _col) when c in [?\n, ?\r], do: advance(rest, line + 1, 1)
  defp advance([_ | rest], line, col), do: advance(rest, line, col + 1)
  defp advance([], line, col), do: {line, col}

  defp block_comment([], _line, _col, _depth, start),
    do: error("unterminated /* comment", start)

  defp block_comment([?*, ?/ | rest], line, col, 1, _start), do: {rest, line, col + 2}

  defp block_comment([?*, ?/ | rest], line, col, depth, start),
    do: block_comment(rest, line, col + 2, depth - 1, start)

  defp block_comment([?/, ?* | rest], line, col, depth, start),
    do: block_comment(rest, line, col + 2, depth + 1, start)

  defp block_comment([?\r, ?\n | rest], line, _col, depth, start),
    do: block_comment(rest, line + 1, 1, depth, start)

  defp block_comment([c | rest], line, _col, depth, start) when c in [?\n, ?\r],
    do: block_comment(rest, line + 1, 1, depth, start)

  defp block_comment([_ | rest], line, col, depth, start),
    do: block_comment(rest, line, col + 1, depth, start)

  # An invalid byte inside a string or quoted name is reported where it is.
  defp check_bytes(matched, {line, col}) do
    case Enum.split_while(matched, &(&1 < @bad_byte)) do
      {_, []} -> :ok
      {before, [bad | _]} -> illegal(bad, advance(before, line, col))
    end
  end

  defp illegal(c, pos) when c >= @bad_byte,
    do: error("invalid UTF-8 byte 0x#{Integer.to_string(c - @bad_byte, 16)}", pos)

  defp illegal(c, pos), do: error("unexpected character #{inspect(<<c::utf8>>)}", pos)

  defp number(text, pos) do
    {mantissa, exp} =
      case :binary.match(text, ["e", "E"]) do
        {at, _} -> {binary_part(text, 0, at), binary_part(text, at, byte_size(text) - at)}
        :nomatch -> {text, ""}
      end

    case String.split(mantissa, ".", parts: 2) do
      [int] when exp == "" ->
        {:integer, String.to_integer(int), pos}

      parts ->
        {int, frac} =
          case parts do
            [int] -> {int, ""}
            [int, frac] -> {int, frac}
          end

        int = if int == "", do: "0", else: int
        frac = if frac == "", do: "0", else: frac
        {:float, to_float("#{int}.#{frac}#{exp}", text, pos), pos}
    end
  end

  defp to_float(normalized, text, pos) do
    String.to_float(normalized)
  rescue
    ArgumentError -> error("number out of range: #{text}", pos)
  end

  # The same character classes as Efsql.SQL.Lexer.
  defp word_start?(c) when c in ?a..?z or c in ?A..?Z or c == ?_, do: true
  defp word_start?(c) when c < 128 or c >= @bad_byte, do: false
  defp word_start?(c), do: String.match?(<<c::utf8>>, ~r/^\p{L}$/u)

  defp word_continue?(c) when c in ?0..?9 or c == ?$, do: true
  defp word_continue?(c) when c < 128 or c >= @bad_byte, do: word_start?(c)
  defp word_continue?(c), do: String.match?(<<c::utf8>>, ~r/^[\p{L}\p{M}\p{N}]$/u)

  defp unicode_space?(c),
    do: c in [0xA0, 0x1680, 0x202F, 0x205F, 0x3000, 0xFEFF] or c in 0x2000..0x200A

  defp error(reason, pos), do: throw({:syntax_error, reason, pos})
end
