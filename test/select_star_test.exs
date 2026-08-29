defmodule EfsqlTest.Integration.SelectStar do
  use EfsqlTest.Case, async: true

  alias Efsql.Exception.Unsupported

  test "select * with an index-field constraint raises", context do
    tenant_id = context[:tenant_id]

    assert_raise(Unsupported, ~r/SELECT \* is not supported for index queries/, fn ->
      Efsql.all("select * from #{tenant_id}.users where name = 'Alice';")
    end)
  end

  test "select * with a residual-only constraint raises", context do
    tenant_id = context[:tenant_id]

    assert_raise(Unsupported, ~r/SELECT \* is not supported for index queries/, fn ->
      Efsql.all("select * from #{tenant_id}.users where notes like '%bar%';")
    end)
  end

  test "select * with in on a field raises", context do
    tenant_id = context[:tenant_id]

    assert_raise(Unsupported, ~r/SELECT \* is not supported for index queries/, fn ->
      Efsql.all("select * from #{tenant_id}.users where name in ('Alice', 'Bob');")
    end)
  end

  test "select * with pk fan-out is supported", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0001"}, %{id: "0003"}] =
             Efsql.all("select * from #{tenant_id}.users where _ in ('0001', '0003');")
             |> Enum.sort_by(& &1.id)
  end

  test "select * with a pk range and residual filter is supported", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0002", name: "Bob"}] =
             Efsql.all("select * from #{tenant_id}.users where _ > '0000' and notes = 'foobar';")
  end

  test "select * of the whole table with order by is supported", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Charles"}, %{name: "Bob"}, %{name: "Alice"}] =
             Efsql.all("select * from #{tenant_id}.users order by name desc;")
  end
end
