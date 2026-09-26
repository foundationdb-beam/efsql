defmodule Efsql.SQL.PropertyTest do
  # Randomized tests. `:rand` is seeded per test from ExUnit's --seed, so a
  # failure reproduces with `mix test --seed N`.
  use ExUnit.Case, async: true

  alias Efsql.Exception.Unsupported
  alias Efsql.SQL.AST.Select
  alias Efsql.SQL.Parser
  alias Efsql.SQL.SyntaxError
  alias EfsqlTest.SQLGen

  @runs 1_000

  test "printing a random tree and parsing it gives the tree back" do
    for _ <- 1..@runs do
      select = SQLGen.select()
      sql = SQLGen.to_sql(select)

      assert Parser.parse(sql) == {:ok, select}, """
      SQL:
      #{sql}
      """
    end
  end

  test "mangled queries parse or fail with a positioned SyntaxError, never crash" do
    for _ <- 1..@runs do
      sql = SQLGen.select() |> SQLGen.to_sql() |> mangle(Enum.random(1..4))
      check(sql)
    end
  end

  test "random bytes parse or fail with a positioned SyntaxError, never crash" do
    alphabet =
      String.graphemes("selctfromwhandi*,.;()'\"=<>!:-+/%_ \n\t0123456789eé") ++
        ["select ", " from ", " where ", " and ", "--", "/*", "*/", "::", <<0xFF>>, <<0>>]

    for _ <- 1..@runs do
      sql = Enum.map_join(1..Enum.random(0..40), fn _ -> Enum.random(alphabet) end)
      check(sql)
    end
  end

  test "valid queries translate to a logical plan or raise Unsupported" do
    for _ <- 1..@runs do
      sql = SQLGen.select() |> SQLGen.to_sql()

      try do
        Efsql.Parser.sql_to_logical(sql)
      rescue
        _ in [Unsupported] ->
          :ok

        # Versionstamps need ecto_foundationdb, which a run without the
        # adapter doesn't have; everything else must be one of the above.
        e in [UndefinedFunctionError] ->
          assert e.module == EctoFoundationDB.Versionstamp
      end
    end
  end

  test "big inputs parse and translate quickly" do
    values = Enum.map_join(1..20_000, ", ", &"'v#{&1}'")
    conditions = Enum.map_join(1..20_000, " and ", &"f#{&1} = #{&1}")
    sql = "select a from t where a in (#{values}) and #{conditions}"

    {micros, %Efsql.Logical.Select{predicates: predicates}} =
      :timer.tc(fn -> Efsql.Parser.sql_to_logical(sql) end)

    assert length(predicates) == 20_001
    assert micros < 5_000_000
  end

  defp check(sql) do
    case Parser.parse(sql) do
      {:ok, %Select{}} ->
        :ok

      {:error, %SyntaxError{line: line, column: column, reason: reason}} ->
        assert is_binary(reason) and reason != ""
        lines = String.split(sql, ["\r\n", "\n", "\r"])
        assert line in 1..length(lines), "line #{line} out of range for #{inspect(sql)}"
        assert column >= 1, "column #{column} for #{inspect(sql)}"
    end
  end

  # Random edits: delete, insert, replace, duplicate or truncate.
  defp mangle(sql, 0), do: sql

  defp mangle(sql, n) do
    chars = String.graphemes(sql)
    size = length(chars)
    at = Enum.random(0..size)

    junk =
      Enum.random([
        "(",
        ")",
        "'",
        "\"",
        ",",
        ";",
        "-",
        "*",
        ":",
        ".",
        "=",
        "<",
        "not",
        " and ",
        "é",
        <<0xC3>>
      ])

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
end
