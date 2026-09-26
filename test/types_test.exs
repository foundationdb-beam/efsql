defmodule Efsql.TypesTest do
  use ExUnit.Case, async: true

  alias Efsql.Types

  describe "compare" do
    test "datetimes compare chronologically, not by struct fields" do
      # Term order compares the structs' fields alphabetically, so day 2 of
      # a later year would sort before day 3 of an earlier one.
      assert Types.compare(~N[2025-01-02 00:00:00], ~N[2024-01-03 00:00:00]) == :gt
      assert Types.compare(~U[2025-01-02 00:00:00Z], ~U[2024-01-03 00:00:00Z]) == :gt
    end

    test "datetimes equal regardless of precision" do
      assert Types.compare(~N[2024-03-01 12:34:56.000000], ~N[2024-03-01 12:34:56]) == :eq
      assert Types.compare(~U[2024-03-01 12:34:56.000000Z], ~U[2024-03-01 12:34:56Z]) == :eq
    end

    test "a NaiveDateTime never equals a DateTime" do
      refute Types.compare(~N[2024-03-01 12:34:56], ~U[2024-03-01 12:34:56Z]) == :eq
    end

    test "dates and times compare chronologically" do
      # Term order compares Date's fields alphabetically, year last.
      assert Types.compare(~D[2025-01-02], ~D[2024-01-03]) == :gt
      # ... and Time's microsecond before its minute.
      assert Types.compare(~T[09:00:00.9], ~T[09:01:00]) == :lt
      assert Types.compare(~T[09:00:00.000000], ~T[09:00:00]) == :eq
    end

    test "decimals compare by value, against decimals and numbers" do
      # Term order puts every number below every map.
      assert Types.compare(Decimal.new("10.5"), 100) == :lt
      assert Types.compare(100, Decimal.new("10.5")) == :gt
      assert Types.compare(Decimal.new("10.5"), 10.5) == :eq
      assert Types.compare(Decimal.new("0.1"), 0.1) == :eq
      assert Types.compare(Decimal.new("1.50"), Decimal.new("1.5")) == :eq
      assert Types.compare(Decimal.new("2"), 2) == :eq
      assert Types.compare(Decimal.new("-3"), Decimal.new("2")) == :lt
    end

    test "a decimal NaN or non-number falls back to term order instead of raising" do
      assert Types.compare(Decimal.new("NaN"), 1) in [:lt, :gt]
      assert Types.compare(Decimal.new("1"), "1") in [:lt, :gt]
    end

    test "other values use term order" do
      assert Types.compare("a", "b") == :lt
      assert Types.compare(2, 1) == :gt
      assert Types.compare(1, 1.0) == :eq
      assert Types.compare(:a, :a) == :eq
    end
  end

  describe "index_key" do
    test "datetimes encode as the adapter's index does" do
      assert Types.index_key(~N[2024-03-01 12:34:56]) == "20240301T123456.000000"
      assert Types.index_key(~U[2024-03-01 12:34:56Z]) == "20240301T123456.000000Z"
      assert Types.index_key(~D[2024-03-01]) == "20240301"
      assert Types.index_key(~T[12:34:56]) == "123456.000000"
    end

    test "other values pass through" do
      assert Types.index_key("x") == "x"
      assert Types.index_key(:active) == :active
    end
  end
end
