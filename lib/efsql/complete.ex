defmodule Efsql.Complete do
  @moduledoc """
  Context-aware completion for the query editor. Pure:
  `complete(input, context)` looks at the text left of the cursor (the
  input is the text up to the cursor) and returns `{word_start, candidates}`
  where `word_start` is the byte offset of the word being completed.

  The keyword set tracks exactly what the query pipeline supports, so
  completion doubles as documentation of the SQL surface.

  Context: `%{tables: [binary], fields: %{table => [binary]}}` from the
  session's discovery cache.
  """

  @statement_start ~w(select)
  @post_expr ~w(and order limit)
  @operators ~w(= > >= < <= like in between not)

  def complete(input, context) do
    {word_start, word} = current_word(input)
    before = input |> binary_part(0, word_start) |> String.downcase()
    tokens = tokenize(before)

    candidates =
      tokens
      |> Enum.reverse()
      |> candidates_for(context, tokens)
      |> Enum.filter(&String.starts_with?(String.downcase(&1), String.downcase(word)))
      |> Enum.uniq()

    {word_start, candidates}
  end

  defp candidates_for([], _context, _tokens), do: @statement_start

  defp candidates_for([last | _], context, tokens) do
    cond do
      last == "select" or last == "," ->
        fields(context, tokens) ++ ["*"]

      last == "from" ->
        context.tables

      last in ["where", "and", "not"] ->
        fields(context, tokens)

      last == "order" ->
        ~w(by)

      last == "by" ->
        fields(context, tokens)

      last in ["asc", "desc"] ->
        @post_expr -- ["order"]

      last in @operators ->
        []

      # after a field name in select-list or predicate position
      true ->
        case section(tokens) do
          :select -> ~w(from)
          :from -> ~w(where order limit)
          :where -> @operators
          :order_by -> ~w(asc desc limit)
          _ -> []
        end
    end
  end

  defp fields(context, tokens) do
    case table(tokens) do
      nil -> context.fields |> Map.values() |> List.flatten() |> Enum.uniq()
      table -> Map.get(context.fields, table, [])
    end
  end

  # the table named after `from`, stripped of tenant qualification
  defp table(tokens) do
    case Enum.drop_while(tokens, &(&1 != "from")) do
      ["from", table | _] -> table |> String.split(".") |> List.last()
      _ -> nil
    end
  end

  defp section(tokens) do
    tokens
    |> Enum.reverse()
    |> Enum.find_value(:start, fn
      "by" -> :order_by
      "where" -> :where
      "from" -> :from
      "select" -> :select
      _ -> nil
    end)
  end

  defp current_word(input) do
    len = byte_size(input)

    start =
      input
      |> String.reverse()
      |> String.graphemes()
      |> Enum.take_while(&word_char?/1)
      |> Enum.map(&byte_size/1)
      |> Enum.sum()

    {len - start, binary_part(input, len - start, start)}
  end

  defp word_char?(g), do: String.match?(g, ~r/[\w.*]/u)

  defp tokenize(text) do
    text
    |> String.replace(",", " , ")
    |> String.split(~r/\s+/, trim: true)
  end
end
