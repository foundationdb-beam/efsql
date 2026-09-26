defmodule EfsqlTest.Integration.GroupBy do
  use EfsqlTest.Case, async: true

  alias Efsql.Exception.Unsupported
  alias Efsql.Physical.Plan

  # Alice "Lorem ipsum", Bob "foobar", Charles with no notes.

  test "count(*) over the whole table", context do
    assert [%{"count(*)": 3}] = Efsql.all("select count(*) from #{context[:tenant_id]}.users;")
  end

  test "count of a field skips NULLs", context do
    assert [%{n: 2}] = Efsql.all("select count(notes) as n from #{context[:tenant_id]}.users;")
  end

  test "min and max", context do
    assert [%{"min(name)": "Alice", "max(name)": "Charles"}] =
             Efsql.all("select min(name), max(name) from #{context[:tenant_id]}.users;")
  end

  test "one row per group, NULLs grouped together", context do
    rows =
      Efsql.all("select notes, count(*) as n from #{context[:tenant_id]}.users group by notes;")

    assert rows == [
             %{notes: "Lorem ipsum", n: 1},
             %{notes: "foobar", n: 1},
             %{notes: nil, n: 1}
           ]
  end

  test "WHERE narrows the rows before grouping", context do
    assert [%{n: 2}] =
             Efsql.all(
               "select count(*) as n from #{context[:tenant_id]}.users where name > 'Alice';"
             )
  end

  test "an aggregate of no rows is one row", context do
    assert [%{n: 0, "max(name)": nil}] =
             Efsql.all(
               "select count(*) as n, max(name) from #{context[:tenant_id]}.users where name = 'Zed';"
             )
  end

  test "ORDER BY and LIMIT apply to the groups", context do
    assert [%{notes: nil}, %{notes: "foobar"}] =
             Efsql.all(
               "select notes from #{context[:tenant_id]}.users group by notes " <>
                 "order by notes desc limit 2;"
             )
  end

  test "fields grouped but not selected are projected away", context do
    assert [%{n: 1}, %{n: 1}, %{n: 1}] =
             rows =
             Efsql.all("select count(*) as n from #{context[:tenant_id]}.users group by notes;")

    assert Enum.all?(rows, &(Map.keys(&1) == [:n]))
  end

  test "sum of text is unsupported", context do
    assert_raise Unsupported, ~r/sum and avg need numbers/, fn ->
      Efsql.all("select sum(name) from #{context[:tenant_id]}.users;")
    end
  end

  test "the scan keeps its pushdown and reads only the fields it needs", context do
    {%Plan{} = plan, _rows, _tenants} =
      Efsql.qall(
        "select notes, count(*) from #{context[:tenant_id]}.users where name = 'Bob' " <>
          "group by notes order by notes limit 5;"
      )

    assert {:index_scan, %Ecto.Query{wheres: [_]} = query, _opts} = plan.access
    assert %{take: %{0 => {:any, [:notes]}}} = query.select
    assert query.limit == nil

    assert [
             {:aggregate, [:notes], [{:"count(*)", :count, :star}]},
             {:sort, [asc: :notes]},
             {:limit, 5}
           ] = plan.ops
  end
end
