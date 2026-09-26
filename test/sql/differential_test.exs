defmodule Efsql.SQL.DifferentialTest do
  # The two front ends side by side: the hand-written lexer and parser, and
  # the ones built on leex and yecc, must give the same result for any
  # input: the same tokens, the same tree, or the same error at the same
  # position. Inputs are valid queries, mangled ones and garbage in equal
  # measure; reproduce a failure with `mix test --seed N`.
  use ExUnit.Case, async: true

  alias EfsqlTest.SQLGen

  @runs 3_000

  test "the lexers agree on every input" do
    for _ <- 1..@runs do
      sql = SQLGen.any_input()

      assert Efsql.SQL.Leex.tokenize(sql) == Efsql.SQL.Lexer.tokenize(sql),
             "input: #{inspect(sql)}"
    end
  end

  test "the parsers agree on every input" do
    for _ <- 1..@runs do
      sql = SQLGen.any_input()
      assert Efsql.SQL.Yecc.parse(sql) == Efsql.SQL.Parser.parse(sql), "input: #{inspect(sql)}"
    end
  end
end
