defmodule EfsqlTest.Integration.Or do
  use EfsqlTest.Case, async: true

  alias Efsql.Exception.Unsupported
  alias Efsql.Physical.Plan

  # Alice "Lorem ipsum", Bob "foobar", Charles with no notes.

  defp names(context, condition, rest \\ "") do
    "select name from #{context[:tenant_id]}.users where #{condition}#{rest};"
    |> Efsql.all()
    |> Enum.map(& &1.name)
  end

  defp sorted_names(context, condition), do: context |> names(condition) |> Enum.sort()

  test "OR across fields, checked on the rows read", context do
    {%Plan{access: {:pk_range, _, nil, nil, _}, ops: ops}, _rows, _} =
      Efsql.qall(
        "select name from #{context[:tenant_id]}.users where name = 'Alice' or notes = 'foobar';"
      )

    assert [{:filter, [{:or, _}]} | _] = ops
    assert sorted_names(context, "name = 'Alice' or notes = 'foobar'") == ["Alice", "Bob"]
  end

  test "a NULL fails only its own branch", context do
    assert sorted_names(context, "notes = 'foobar' or name = 'Charles'") == ["Bob", "Charles"]
    assert sorted_names(context, "notes <> 'foobar' or notes is null") == ["Alice", "Charles"]
  end

  test "AND binds tighter than OR, and parentheses group", context do
    assert sorted_names(context, "name = 'Alice' and notes is null or name = 'Bob'") == ["Bob"]

    assert sorted_names(context, "name = 'Alice' and (notes is null or name = 'Bob')") == []

    assert sorted_names(context, "name >= 'B' and (notes is null or notes like 'foo%')") ==
             ["Bob", "Charles"]
  end

  test "NOT over AND is an OR", context do
    assert sorted_names(context, "not (name >= 'B' and notes is null)") == ["Alice", "Bob"]
  end

  test "an OR of equalities on an indexed field reads each value", context do
    {%Plan{access: {:union, [_, _]}}, rows, _} =
      Efsql.qall(
        "select name from #{context[:tenant_id]}.users " <>
          "where name = 'Alice' or name = 'Charles' or name in ('Alice');"
      )

    assert rows |> Enum.map(& &1.name) |> Enum.sort() == ["Alice", "Charles"]
  end

  test "an OR of keys reads each key", context do
    {%Plan{access: {:union, [_, _]}}, rows, _} =
      Efsql.qall("select id from #{context[:tenant_id]}.users where _ = '0001' or _ = '0003';")

    assert rows |> Enum.map(& &1.id) |> Enum.sort() == ["0001", "0003"]
  end

  test "an IN reads a repeated value once", context do
    assert names(context, "name in ('Bob', 'Bob')") == ["Bob"]
  end

  test "ORDER BY and LIMIT apply after the OR", context do
    assert names(context, "name = 'Alice' or notes is null", " order by name desc limit 1") ==
             ["Charles"]
  end

  test "the primary key '_' in an OR only as a key lookup", context do
    assert_raise Unsupported, ~r/on the primary key '_'.*an OR of = and IN/, fn ->
      names(context, "_ = '0001' or name = 'Bob'")
    end

    # the key's own field works anywhere
    assert sorted_names(context, "id = '0001' or name = 'Bob'") == ["Alice", "Bob"]
  end
end
