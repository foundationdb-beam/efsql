defmodule Efsql.PredicateTest do
  use ExUnit.Case, async: true

  alias Efsql.Predicate

  @row %{name: "Alice", age: 30, notes: nil, at: ~D[2024-03-01], price: Decimal.new("9.50")}

  defp holds?(predicate, row \\ @row), do: Predicate.matches?(row, [predicate])

  test "comparisons use Types.compare, so dates and Decimals compare by value" do
    assert holds?({:cmp, :==, :age, 30})
    assert holds?({:cmp, :>=, :at, ~D[2024-01-01]})
    refute holds?({:cmp, :<, :at, ~D[2024-01-01]})
    assert holds?({:cmp, :<, :price, 10})
    assert holds?({:range, :age, {:>, 20}, {:<=, 30}})
    refute holds?({:range, :age, {:>, 30}, {:<=, 40}})
  end

  test "LIKE and IN" do
    assert holds?({:like, :name, "Al%"})
    assert holds?({:like, :name, "_lice"})
    refute holds?({:like, :name, "al%"})
    assert holds?({:not_like, :name, "B%"})
    assert holds?({:in, :age, [10, 30]})
    refute holds?({:in, :age, [10, 20]})
  end

  test "a NULL field matches no comparison, LIKE or IN, not even NOT LIKE" do
    for predicate <- [
          {:cmp, :==, :notes, "x"},
          {:range, :notes, {:>, "a"}, {:<, "z"}},
          {:like, :notes, "%"},
          {:not_like, :notes, "x"},
          {:in, :notes, ["x"]},
          {:cmp, :==, :missing, 1}
        ] do
      refute holds?(predicate), inspect(predicate)
    end

    assert holds?({:is_null, :notes})
    assert holds?({:is_null, :missing})
    refute holds?({:not_null, :notes})
    assert holds?({:not_null, :name})
  end

  test "every predicate must hold" do
    assert Predicate.matches?(@row, [])
    refute Predicate.matches?(@row, [{:cmp, :==, :age, 30}, {:is_null, :name}])
  end

  test "field" do
    for {predicate, field} <- [
          {{:cmp, :==, :a, 1}, :a},
          {{:range, :b, {:>, 1}, {:<, 2}}, :b},
          {{:like, :c, "x"}, :c},
          {{:not_like, :d, "x"}, :d},
          {{:in, :e, [1]}, :e},
          {{:is_null, :f}, :f},
          {{:not_null, :g}, :g}
        ] do
      assert Predicate.field(predicate) == field
    end
  end

  test "pushdown says how the planner can serve a predicate" do
    assert Predicate.pushdown({:cmp, :==, :_, "k"}) == :key
    assert Predicate.pushdown({:range, :_, {:>=, "a"}, {:<, "b"}}) == :key
    assert Predicate.pushdown({:in, :_, ["a", "b"]}) == :in
    assert Predicate.pushdown({:in, :name, ["a"]}) == :in
    assert Predicate.pushdown({:cmp, :>, :age, 1}) == :index
    assert Predicate.pushdown({:range, :age, {:>, 1}, {:<, 2}}) == :index

    for predicate <- [{:like, :a, "x"}, {:not_like, :a, "x"}, {:is_null, :a}, {:not_null, :a}] do
      assert Predicate.pushdown(predicate) == :filter
    end
  end

  test "equality and range" do
    assert Predicate.equality?({:cmp, :==, :a, 1})
    refute Predicate.equality?({:cmp, :>, :a, 1})
    assert Predicate.range?({:cmp, :<=, :a, 1})
    assert Predicate.range?({:range, :a, {:>, 1}, {:<, 2}})
    refute Predicate.range?({:cmp, :==, :a, 1})
    refute Predicate.range?({:like, :a, "x"})
  end

  test "to_ecto encodes values as the index stores them" do
    ref = Predicate.field_ref(:at)
    assert {:>=, [], [^ref, "20240301"]} = Predicate.to_ecto({:cmp, :>=, :at, ~D[2024-03-01]})

    assert {{:>, [], [_, 1]}, {:<, [], [_, 2]}} =
             Predicate.to_ecto({:range, :age, {:>, 1}, {:<, 2}})

    assert_raise Efsql.Exception.Unsupported, fn -> Predicate.to_ecto({:like, :a, "x"}) end
  end
end
