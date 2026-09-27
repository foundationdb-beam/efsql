defmodule EfsqlTest.Integration.Negation do
  use EfsqlTest.Case, async: true

  alias Efsql.Exception.Unsupported
  alias Efsql.Physical.Plan

  # Alice "Lorem ipsum", Bob "foobar", Charles with no notes.

  defp names(context, condition) do
    "select name from #{context[:tenant_id]}.users where #{condition};"
    |> Efsql.all()
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  test "<> and != and NOT (=)", context do
    for condition <- ["name <> 'Bob'", "name != 'Bob'", "not (name = 'Bob')"] do
      assert names(context, condition) == ["Alice", "Charles"], condition
    end
  end

  test "a NULL field is neither equal nor unequal", context do
    assert names(context, "notes <> 'foobar'") == ["Alice"]
    assert names(context, "notes not in ('foobar')") == ["Alice"]
    assert names(context, "notes not like 'foo%'") == ["Alice"]
  end

  test "NOT IN and NOT BETWEEN", context do
    assert names(context, "name not in ('Alice', 'Bob')") == ["Charles"]
    assert names(context, "not name in ('Alice', 'Bob')") == ["Charles"]
    assert names(context, "name not between 'B' and 'Bz'") == ["Alice", "Charles"]
  end

  test "ILIKE and NOT ILIKE ignore case", context do
    assert names(context, "name ilike 'al%'") == ["Alice"]
    assert names(context, "name ilike '%E%'") == ["Alice", "Charles"]
    assert names(context, "name not ilike 'a%'") == ["Bob", "Charles"]
  end

  test "NOT over IS NULL and over OR", context do
    assert names(context, "not (notes is null)") == ["Alice", "Bob"]
    assert names(context, "not (name = 'Alice' or name = 'Bob')") == ["Charles"]
  end

  test "a negation is checked on the rows read, alongside what an index serves", context do
    {%Plan{access: access, ops: ops}, rows, _} =
      Efsql.qall(
        "select name from #{context[:tenant_id]}.users where name >= 'B' and name <> 'Bob';"
      )

    assert {:index_scan, %Ecto.Query{wheres: [_]}, _} = access
    assert {:filter, [{:cmp, :!=, :name, "Bob"}]} in ops
    assert rows == [%{name: "Charles"}]
  end

  test "the primary key takes only what a key range can serve", context do
    assert_raise Unsupported, ~r/on the primary key '_', only =, <, <=, >, >=/, fn ->
      Efsql.all("select name from #{context[:tenant_id]}.users where _ <> '0001';")
    end
  end
end
