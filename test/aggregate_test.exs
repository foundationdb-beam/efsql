defmodule Efsql.AggregateTest do
  use ExUnit.Case, async: true

  alias Efsql.Aggregate
  alias Efsql.Exception.Unsupported

  @rows [
    %{city: "Osaka", age: 30, name: "a"},
    %{city: "Lima", age: 40, name: "b"},
    %{city: "Osaka", age: nil, name: "c"},
    %{city: nil, age: 25, name: "d"},
    %{city: "Osaka", age: 50, name: "e"}
  ]

  test "one row per group, ordered by key with NULLs last" do
    assert Aggregate.run(@rows, [:city], [{:n, :count, :star}]) == [
             %{city: "Lima", n: 1},
             %{city: "Osaka", n: 3},
             %{city: nil, n: 1}
           ]
  end

  test "count(*) counts rows, every other aggregate skips NULLs" do
    assert [_, osaka, _] =
             Aggregate.run(@rows, [:city], [
               {:rows, :count, :star},
               {:ages, :count, :age},
               {:sum, :sum, :age},
               {:avg, :avg, :age},
               {:min, :min, :age},
               {:max, :max, :age}
             ])

    assert osaka == %{city: "Osaka", rows: 3, ages: 2, sum: 80, avg: 40.0, min: 30, max: 50}
  end

  test "no group fields means one group over every row" do
    assert Aggregate.run(@rows, [], [{:n, :count, :star}, {:first, :min, :name}]) == [
             %{n: 5, first: "a"}
           ]
  end

  test "an aggregate over no rows is still one row; a grouping over none is no rows" do
    assert Aggregate.run([], [], [{:n, :count, :star}, {:c, :count, :age}, {:s, :sum, :age}]) ==
             [%{n: 0, c: 0, s: nil}]

    assert Aggregate.run([], [:city], [{:n, :count, :star}]) == []
  end

  test "sum, min and max of only NULLs are NULL" do
    rows = [%{age: nil}, %{}]

    assert Aggregate.run(rows, [], [{:s, :sum, :age}, {:a, :avg, :age}, {:m, :min, :age}]) ==
             [%{s: nil, a: nil, m: nil}]
  end

  test "sum and avg are Decimal when any input is" do
    rows = [%{p: Decimal.new("1.50")}, %{p: 2}, %{p: 0.5}]

    assert [%{s: s, a: a}] = Aggregate.run(rows, [], [{:s, :sum, :p}, {:a, :avg, :p}])
    assert Decimal.equal?(s, Decimal.new("4.0"))
    assert Decimal.equal?(Decimal.round(a, 3), Decimal.new("1.333"))
  end

  test "sum of anything but numbers is unsupported" do
    assert_raise Unsupported, ~r/sum and avg need numbers, but name holds "a"/, fn ->
      Aggregate.run(@rows, [], [{:s, :sum, :name}])
    end
  end

  test "equal values group together whatever their term" do
    rows = [
      %{d: Decimal.new("1.0")},
      %{d: Decimal.new("1.00")},
      %{d: ~N[2024-01-01 00:00:00]},
      %{d: ~N[2024-01-01 00:00:00.000000]}
    ]

    assert [%{n: 2}, %{n: 2}] = Aggregate.run(rows, [:d], [{:n, :count, :star}])
  end

  test "min and max order datetimes chronologically" do
    rows = [%{at: ~D[2024-05-01]}, %{at: ~D[2023-12-31]}, %{at: ~D[2024-01-15]}]

    assert Aggregate.run(rows, [], [{:first, :min, :at}, {:last, :max, :at}]) ==
             [%{first: ~D[2023-12-31], last: ~D[2024-05-01]}]
  end
end
