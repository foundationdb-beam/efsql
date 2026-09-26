defmodule Efsql.SQL.PropertyTest do
  # Randomized tests, run against both parsers. `:rand` is seeded per test
  # from ExUnit's --seed, so a failure reproduces with `mix test --seed N`.
  use ExUnit.Case,
    async: true,
    parameterize: [%{parser: Efsql.SQL.Parser}, %{parser: Efsql.SQL.Yecc}]

  alias Efsql.Exception.Unsupported
  alias Efsql.SQL.AST.Select
  alias Efsql.SQL.SyntaxError
  alias EfsqlTest.SQLGen

  @runs 1_000

  test "printing a random tree and parsing it gives the tree back", %{parser: parser} do
    for _ <- 1..@runs do
      select = SQLGen.select()
      sql = SQLGen.to_sql(select)

      assert parser.parse(sql) == {:ok, select}, """
      SQL:
      #{sql}
      """
    end
  end

  test "mangled queries parse or fail with a positioned SyntaxError, never crash",
       %{parser: parser} do
    for _ <- 1..@runs do
      check(parser, SQLGen.select() |> SQLGen.to_sql() |> SQLGen.mangle(Enum.random(1..4)))
    end
  end

  test "random bytes parse or fail with a positioned SyntaxError, never crash",
       %{parser: parser} do
    for _ <- 1..@runs, do: check(parser, SQLGen.garbage())
  end

  test "valid queries translate to a logical plan or raise Unsupported", %{parser: parser} do
    for _ <- 1..@runs do
      {:ok, select} = parser.parse(SQLGen.select() |> SQLGen.to_sql())

      try do
        Efsql.Parser.to_logical(select)
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

  test "big inputs parse and translate quickly", %{parser: parser} do
    values = Enum.map_join(1..20_000, ", ", &"'v#{&1}'")
    conditions = Enum.map_join(1..20_000, " and ", &"f#{&1} = #{&1}")
    sql = "select a from t where a in (#{values}) and #{conditions}"

    {micros, %Efsql.Logical.Select{predicates: predicates}} =
      :timer.tc(fn -> sql |> parser.parse!() |> Efsql.Parser.to_logical() end)

    assert length(predicates) == 20_001
    assert micros < 5_000_000
  end

  defp check(parser, sql) do
    case parser.parse(sql) do
      {:ok, %Select{}} ->
        :ok

      {:error, %SyntaxError{line: line, column: column, reason: reason}} ->
        assert is_binary(reason) and reason != ""
        lines = String.split(sql, ["\r\n", "\n", "\r"])
        assert line in 1..length(lines), "line #{line} out of range for #{inspect(sql)}"
        assert column >= 1, "column #{column} for #{inspect(sql)}"
    end
  end
end
