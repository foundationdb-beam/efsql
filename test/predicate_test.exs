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

  test "negations and ILIKE" do
    assert holds?({:cmp, :!=, :age, 31})
    refute holds?({:cmp, :!=, :age, 30})
    assert holds?({:cmp, :!=, :price, Decimal.new("9.49")})
    refute holds?({:cmp, :!=, :price, Decimal.new("9.500")})
    assert holds?({:not_in, :age, [10, 20]})
    refute holds?({:not_in, :age, [10, 30]})
    assert holds?({:not_range, :age, {:>=, 31}, {:<=, 40}})
    refute holds?({:not_range, :age, {:>=, 30}, {:<=, 40}})
    assert holds?({:ilike, :name, "al%"})
    assert holds?({:ilike, :name, "ALICE"})
    refute holds?({:not_ilike, :name, "a_ice"})
    assert Predicate.matches?(%{name: "Émile"}, [{:ilike, :name, "émile"}])
  end

  test "a NULL field matches no negation either" do
    for predicate <- [
          {:cmp, :!=, :notes, "x"},
          {:not_in, :notes, ["x"]},
          {:not_range, :notes, {:>=, "a"}, {:<=, "b"}},
          {:ilike, :notes, "%"},
          {:not_ilike, :notes, "x"}
        ] do
      refute holds?(predicate), inspect(predicate)
    end
  end

  test "OR holds when any branch does, a NULL failing only its own branch" do
    assert holds?({:or, [[{:cmp, :==, :age, 1}], [{:cmp, :==, :name, "Alice"}]]})
    refute holds?({:or, [[{:cmp, :==, :age, 1}], [{:cmp, :==, :name, "Bob"}]]})
    assert holds?({:or, [[{:cmp, :==, :notes, "x"}], [{:cmp, :>, :age, 20}]]})
    refute holds?({:or, [[{:cmp, :==, :notes, "x"}], [{:cmp, :!=, :notes, "x"}]]})

    # a branch is AND-ed, and may hold another OR
    refute holds?({:or, [[{:cmp, :==, :age, 30}, {:is_null, :name}], [{:is_null, :age}]]})

    assert holds?(
             {:or,
              [
                [{:is_null, :age}],
                [{:cmp, :==, :age, 30}, {:or, [[{:is_null, :name}], [{:like, :name, "A%"}]]}]
              ]}
           )
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
          {{:not_null, :g}, :g},
          {{:cmp, :!=, :h, 1}, :h},
          {{:not_in, :i, [1]}, :i},
          {{:not_range, :j, {:>=, 1}, {:<=, 2}}, :j},
          {{:ilike, :k, "x"}, :k},
          {{:not_ilike, :l, "x"}, :l}
        ] do
      assert Predicate.field(predicate) == field
      assert Predicate.fields(predicate) == [field]
    end

    assert Predicate.fields(
             {:or,
              [
                [{:cmp, :==, :a, 1}, {:is_null, :b}],
                [{:or, [[{:in, :a, [2]}], [{:is_null, :c}]]}]
              ]}
           ) == [:a, :b, :c]
  end

  test "pushdown says how the planner can serve a predicate" do
    assert Predicate.pushdown({:cmp, :==, :_, "k"}) == :key
    assert Predicate.pushdown({:range, :_, {:>=, "a"}, {:<, "b"}}) == :key
    assert Predicate.pushdown({:in, :_, ["a", "b"]}) == :in
    assert Predicate.pushdown({:in, :name, ["a"]}) == :in
    assert Predicate.pushdown({:cmp, :>, :age, 1}) == :index
    assert Predicate.pushdown({:range, :age, {:>, 1}, {:<, 2}}) == :index

    for predicate <- [
          {:like, :a, "x"},
          {:not_like, :a, "x"},
          {:ilike, :a, "x"},
          {:not_ilike, :a, "x"},
          {:is_null, :a},
          {:not_null, :a},
          {:cmp, :!=, :a, 1},
          {:cmp, :!=, :_, "k"},
          {:not_in, :a, [1]},
          {:not_range, :a, {:>=, 1}, {:<=, 2}},
          {:or, [[{:cmp, :==, :a, 1}], [{:cmp, :==, :b, 2}]]}
        ] do
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
