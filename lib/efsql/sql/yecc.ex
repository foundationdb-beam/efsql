defmodule Efsql.SQL.Yecc do
  @moduledoc """
  The same contract as `Efsql.SQL.Parser`, built on leex and yecc: the
  tokens come from `Efsql.SQL.Leex` and the grammar is
  `src/efsql_sql_yecc.yrl`.

  yecc reports only the token a syntax error stopped at, so the error's
  wording is worked out by `Efsql.SQL.Yecc.Explain` from the tokens
  before it.
  """

  alias Efsql.SQL.AST
  alias Efsql.SQL.Leex
  alias Efsql.SQL.SyntaxError
  alias Efsql.SQL.Yecc.Explain

  # Words the grammar has as terminals. They must match its Terminals.
  @keywords Efsql.SQL.Parser.reserved_words() ++ ~w[time timestamp without zone]

  @spec parse(String.t()) :: {:ok, AST.Select.t()} | {:error, SyntaxError.t()}
  def parse(sql) when is_binary(sql) do
    with {:ok, tokens} <- Leex.tokenize(sql) do
      # A token's location is its index, so an error names its token
      # exactly (end of input can share a position with another token).
      ytokens = tokens |> Enum.with_index() |> Enum.map(fn {t, i} -> to_yecc(t, i) end)

      case :efsql_sql_yecc.parse(ytokens) do
        {:ok, {:select, fields, from, where, order_by, limit}} ->
          {:ok,
           %AST.Select{fields: fields, from: from, where: where, order_by: order_by, limit: limit}}

        {:error, {index, :efsql_sql_yecc, _message}} ->
          {reason, {line, column}} = Explain.explain(tokens, index)
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

  defp to_yecc({:word, word, _}, i) when word in @keywords, do: {String.to_atom(word), i, word}
  defp to_yecc({:word, word, _}, i), do: {:ident, i, word}
  defp to_yecc({:op, op, _}, i), do: {op, i, op}
  defp to_yecc({:eof, nil, _}, i), do: {:"$end", i}
  defp to_yecc({type, value, _}, i), do: {type, i, value}
end
