defmodule Efsql.SQL.SyntaxError do
  @moduledoc """
  Raised (or returned) when SQL text can't be lexed or parsed. `line` and
  `column` are 1-based and count characters, not bytes.
  """

  defexception [:reason, :line, :column]

  @impl true
  def message(%__MODULE__{reason: reason, line: line, column: column}) do
    "syntax error at line #{line}, column #{column}: #{reason}"
  end
end
