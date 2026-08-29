defmodule EfsqlTest.Integration.SelectStar do
  use EfsqlTest.Case, async: true

  test "select * with an index-field constraint returns full objects", context do
    tenant_id = context[:tenant_id]

    assert {plan, [%{id: "0001", name: "Alice", notes: "Lorem ipsum"}], _tenants} =
             Efsql.qall("select * from #{tenant_id}.users where name = 'Alice';")

    assert {:all_from_source, %Ecto.Query{select: nil, wheres: [_]}, _opts} = plan.access
  end

  test "select * with an index range", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Alice"}, %{name: "Bob"}] =
             Efsql.all("select * from #{tenant_id}.users where name between 'A' and 'C';")
  end

  test "select * with a residual-only constraint", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0002", name: "Bob"}] =
             Efsql.all("select * from #{tenant_id}.users where notes like '%bar%';")
  end

  test "select * with in on an indexed field fans out", context do
    tenant_id = context[:tenant_id]

    assert {plan, rows, _tenants} =
             Efsql.qall("select * from #{tenant_id}.users where name in ('Alice', 'Bob');")

    assert {:union, [{:all_from_source, _, _}, {:all_from_source, _, _}]} = plan.access
    assert [%{name: "Alice"}, %{name: "Bob"}] = Enum.sort_by(rows, & &1.name)
  end

  test "select * with pk fan-out", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0001"}, %{id: "0003"}] =
             Efsql.all("select * from #{tenant_id}.users where _ in ('0001', '0003');")
             |> Enum.sort_by(& &1.id)
  end

  test "select * with a pk range and residual filter", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0002", name: "Bob"}] =
             Efsql.all("select * from #{tenant_id}.users where _ > '0000' and notes = 'foobar';")
  end

  test "select * with native order by and limit", context do
    tenant_id = context[:tenant_id]

    assert {plan, [%{name: "Charles"}, %{name: "Bob"}], _tenants} =
             Efsql.qall("select * from #{tenant_id}.users order by name desc limit 2;")

    assert {:all_from_source, %Ecto.Query{order_bys: [_], limit: %{expr: 2}}, _opts} = plan.access
    assert plan.ops == []
  end
end
