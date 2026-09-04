defmodule Efsql.Tui.ColumnsTest do
  use ExUnit.Case, async: true

  alias Efsql.Tui.Columns

  # DuckDB draws `│`-delimited cells, so a column costs width + 3 and a row
  # starts with one more `│`. Run the sizing in that geometry and the results
  # can be compared against what the duckdb CLI actually prints.
  @duckdb [lead: 4, gutter: 3]

  describe "matches the duckdb CLI" do
    test "a row that fits is not narrowed, even past max_col_width" do
      # duckdb -c "select repeat('a',36) as a" in a wide terminal keeps all 36
      {widths, map} = Columns.layout([36, 7], 100, @duckdb)

      assert widths == [36, 7]
      assert map == [col: 0, col: 1]
    end

    test "over-wide columns clamp left to right, the last taking the slack" do
      # duckdb @ 80 cols, 3 columns of 40 chars, prints widths 20, 20, 30
      {widths, map} = Columns.layout([40, 40, 40], 80, @duckdb)

      assert widths == [20, 20, 30]
      assert map == [col: 0, col: 1, col: 2]
      assert total(widths, @duckdb) == 80
    end

    test "columns that still do not fit are dropped outward from the middle" do
      # duckdb @ 80 cols, 10 columns of 15 chars, prints c1, c2, …, c9, c10
      {widths, map} = Columns.layout(List.duplicate(15, 10), 80, @duckdb)

      assert map == [{:col, 0}, {:col, 1}, :split, {:col, 8}, {:col, 9}]
      assert widths == [15, 15, 1, 15, 15]
    end
  end

  describe "efsql geometry" do
    test "natural widths are kept when the row fits" do
      assert {[5, 30], [col: 0, col: 1]} = Columns.layout([5, 30], 80)
    end

    test "clamping is preferred to dropping a column" do
      {widths, map} = Columns.layout([50, 50], 60)

      assert Enum.all?(map, &match?({:col, _}, &1))
      assert total(widths, []) <= 60
    end

    test "a single column is never dropped" do
      {widths, map} = Columns.layout([500], 10)

      assert map == [col: 0]
      assert widths == [20]
    end

    test "the row always fits once there is room for the split column" do
      for count <- [3, 4, 9, 20], budget <- [40, 60, 80, 120] do
        {widths, _map} = Columns.layout(List.duplicate(30, count), budget)
        assert total(widths, []) <= budget, "#{count} columns in #{budget}"
      end
    end

    test "no columns is not a special case for the caller" do
      assert {[], []} = Columns.layout([], 80)
    end
  end

  defp total(widths, opts) do
    lead = Keyword.get(opts, :lead, 1)
    gutter = Keyword.get(opts, :gutter, 2)
    lead + Enum.sum(widths) + gutter * max(length(widths) - 1, 0)
  end
end
