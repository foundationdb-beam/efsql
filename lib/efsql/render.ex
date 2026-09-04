defmodule Efsql.Render do
  @moduledoc """
  Friendly, Elixir-style rendering of values pulled from FoundationDB.
  `cell/2` renders a value for a table cell (single line, truncated);
  `full/2` renders a value for the Inspector (multi-line, complete).
  """

  def cell(value, width \\ 40) do
    # A cell only ever shows `width` columns, so a big string is cut to a
    # bounded prefix before anything walks it: checking printability of a 50KB
    # value for every cell is what used to make typing lag.
    value
    |> cell_prefix(width)
    |> render(width, false)
    # A cell is one line by contract: a value containing newlines or tabs would
    # otherwise break the frame layout when written to the terminal.
    |> collapse_breaks()
    |> truncate_cell(width)
  end

  # The regex is the expensive part of rendering a cell, and almost no value
  # contains a break at all, so look before running it.
  defp collapse_breaks(text) do
    case :binary.match(text, ["\r", "\n", "\t"]) do
      :nomatch -> text
      _ -> String.replace(text, ~r/[\r\n\t]+/, " ")
    end
  end

  # Generous bytes-per-grapheme budget: combining marks and emoji sequences
  # take several bytes each, and a too-short prefix only costs an ellipsis.
  @bytes_per_cell_grapheme 8

  defp cell_prefix(value, width) when is_binary(value) do
    max_bytes = width * @bytes_per_cell_grapheme

    if byte_size(value) > max_bytes do
      {:prefix, utf8_prefix(value, max_bytes), byte_size(value)}
    else
      value
    end
  end

  defp cell_prefix(value, _width), do: value

  # The longest prefix of at most `n` bytes that does not end mid-codepoint.
  defp utf8_prefix(bin, n) do
    prefix = binary_part(bin, 0, n)
    trim_partial_codepoint(prefix)
  end

  defp trim_partial_codepoint(<<>>), do: <<>>

  defp trim_partial_codepoint(prefix) do
    size = byte_size(prefix)
    last = :binary.last(prefix)

    cond do
      # ASCII byte: never part of a multibyte sequence
      last < 0x80 ->
        prefix

      # a lead byte with no continuation after it: drop it
      last >= 0xC0 ->
        binary_part(prefix, 0, size - 1)

      # continuation byte: complete only if the sequence it belongs to fits
      true ->
        case String.valid?(binary_part(prefix, max(size - 4, 0), min(size, 4))) do
          true -> prefix
          false -> trim_partial_codepoint(binary_part(prefix, 0, size - 1))
        end
    end
  end

  def full(value, width \\ 80) do
    render(value, width, true)
  end

  defp render(nil, _width, _multi), do: "nil"

  defp render(v, _width, _multi) when is_binary(v), do: render_binary(v, byte_size(v))

  # A bounded prefix of a large binary: printable text always ends in an
  # ellipsis, and the hex summary reports the full binary's size.
  defp render({:prefix, prefix, size}, _width, _multi) do
    case render_binary(prefix, size) do
      ^prefix -> prefix <> "…"
      summary -> summary
    end
  end

  defp render({:versionstamp, _, _, _} = v, _width, _multi) do
    "#Versionstamp<#{EctoFoundationDB.Versionstamp.to_integer(v)}>"
  end

  defp render(v, width, multi) do
    inspect(v,
      pretty: multi,
      width: width,
      limit: if(multi, do: :infinity, else: 10),
      printable_limit: if(multi, do: :infinity, else: 64),
      syntax_colors: []
    )
  end

  defp render_binary(v, size) do
    if String.valid?(v) and String.printable?(v) do
      v
    else
      hex = v |> binary_part(0, min(byte_size(v), 8)) |> Base.encode16(case: :lower)
      "<<0x#{hex}#{if size > 8, do: "…"}>> (#{size} bytes)"
    end
  end

  @doc """
  Breaks text into lines no wider than `width`, preserving existing newlines.
  Wraps on spaces where it can and hard-breaks words that are wider than the
  line — a long unbroken value (a token, a URL, a base64 blob) still has to
  fit, and losing its tail to an ellipsis is worse than splitting it.
  """
  def wrap(text, width) when is_binary(text) and width > 0 do
    text
    |> String.split("\n")
    |> Enum.flat_map(&wrap_line(&1, width))
  end

  defp wrap_line("", _width), do: [""]

  defp wrap_line(line, width) do
    if String.length(line) <= width do
      [line]
    else
      line
      |> String.split(" ")
      |> Enum.flat_map(&split_long_word(&1, width))
      |> fill(width)
    end
  end

  defp split_long_word(word, width) do
    if String.length(word) <= width do
      [word]
    else
      word |> String.graphemes() |> Enum.chunk_every(width) |> Enum.map(&Enum.join/1)
    end
  end

  defp fill(words, width) do
    words
    |> Enum.reduce([], fn
      word, [] ->
        [word]

      word, [current | rest] ->
        if String.length(current) + 1 + String.length(word) <= width do
          [current <> " " <> word | rest]
        else
          [word, current | rest]
        end
    end)
    |> Enum.reverse()
  end

  @doc """
  The width of `text` in terminal columns.

  Not its length in characters: a CJK ideograph occupies two columns and a
  combining mark none, so measuring by grapheme count misaligns every column
  to the right of such a value. Uses the same `wcwidth` table the terminal
  itself does, via OTP, with a fast path for the ASCII that most values are.
  """
  def width(text) when is_binary(text) do
    if ascii?(text), do: byte_size(text), else: cluster_width(text, 0)
  end

  defp ascii?(<<>>), do: true
  defp ascii?(<<b, rest::binary>>) when b < 128, do: ascii?(rest)
  defp ascii?(_), do: false

  # Measured per grapheme cluster, so a combining mark costs nothing on its
  # own and an accented letter stays one column wide. `is_wide/1` reads the
  # Unicode East Asian Width table; libc's wcwidth (via prim_tty) was the
  # obvious alternative but answers by the process locale, reporting "á" as
  # zero-width whenever LANG is unset.
  defp cluster_width(text, acc) do
    case String.next_grapheme(text) do
      nil -> acc
      {grapheme, rest} -> cluster_width(rest, acc + grapheme_width(grapheme))
    end
  end

  defp grapheme_width(<<cp::utf8, _rest::binary>>) do
    if :unicode_util.is_wide(cp), do: 2, else: 1
  rescue
    _ -> 1
  end

  defp grapheme_width(_grapheme), do: 1

  @doc """
  Cuts `string` to `width` columns, ending in an ellipsis when it does not fit.
  The result fills the width exactly, for chrome that has to reach a margin.
  """
  def truncate(string, width) do
    cond do
      width <= 0 -> ""
      ascii?(string) -> ascii_truncate(string, width, width - 1)
      fits?(string, width) -> string
      true -> take_width(string, width - 1) <> "…"
    end
  end

  defp ascii_truncate(string, width, keep) do
    if byte_size(string) <= width do
      string
    else
      binary_part(string, 0, max(keep, 0)) <> "…"
    end
  end

  @doc """
  Cuts a table cell to a column of `col_width`, the way the DuckDB CLI does.

  DuckDB counts the ellipsis against the budget and then stops *before*
  filling the column, so a truncated cell renders one column narrower than an
  untruncated one. That is reproduced here deliberately, so column contents
  line up with what `duckdb` prints for the same data.
  """
  def truncate_cell(string, col_width) do
    cond do
      col_width <= 0 -> ""
      ascii?(string) -> ascii_truncate(string, col_width, col_width - 2)
      fits?(string, col_width) -> string
      true -> take_width(string, col_width - 2) <> "…"
    end
  end

  # Whether `string` fits in `limit` columns, without measuring any further
  # than that: a cell may hold far more text than the column can ever show.
  defp fits?(_string, limit) when limit < 0, do: false

  defp fits?(string, limit) do
    case String.next_grapheme(string) do
      nil -> true
      {grapheme, rest} -> fits?(rest, limit - grapheme_width(grapheme))
    end
  end

  # The widest prefix of `string` that fits in `limit` columns. Walks only as
  # far as the limit, never the whole value.
  defp take_width(_string, limit) when limit <= 0, do: ""

  defp take_width(string, limit), do: take_width(string, limit, [])

  defp take_width(string, limit, acc) do
    case String.next_grapheme(string) do
      nil ->
        IO.iodata_to_binary(Enum.reverse(acc))

      {grapheme, rest} ->
        case limit - grapheme_width(grapheme) do
          left when left >= 0 -> take_width(rest, left, [grapheme | acc])
          _ -> IO.iodata_to_binary(Enum.reverse(acc))
        end
    end
  end

  @doc "Pads `text` to `width` columns, cutting it first if it overflows."
  def pad(text, width, align \\ :left) do
    text = truncate(text, width)
    fill = String.duplicate(" ", max(width - width(text), 0))

    case align do
      :left -> text <> fill
      :right -> fill <> text
    end
  end

  @doc "Short name for a value's type, for schema discovery displays."
  def type_of(nil), do: :null
  def type_of(v) when is_boolean(v), do: :boolean
  def type_of(v) when is_integer(v), do: :integer
  def type_of(v) when is_float(v), do: :float
  def type_of({:versionstamp, _, _, _}), do: :versionstamp
  def type_of(%DateTime{}), do: :utc_datetime
  def type_of(%NaiveDateTime{}), do: :naive_datetime
  def type_of(%Date{}), do: :date
  def type_of(%Time{}), do: :time
  def type_of(%Decimal{}), do: :decimal

  # Name other structs after their module, so schema discovery distinguishes
  # a plain map from, say, an Address.
  def type_of(%mod{}), do: mod |> Module.split() |> List.last() |> String.to_atom()

  def type_of(v) when is_map(v), do: :map
  def type_of(v) when is_list(v), do: :list

  def type_of(v) when is_binary(v) do
    if String.valid?(v) and String.printable?(v), do: :string, else: :binary
  end

  def type_of(_), do: :term
end
