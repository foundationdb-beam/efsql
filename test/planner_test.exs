defmodule EfsqlTest.Integration.Planner do
  use EfsqlTest.Case, async: true

  alias Efsql.Physical.Plan

  defp plan(sql) do
    {plan = %Plan{}, _rows, _tenants} = Efsql.qall(sql)
    plan
  end

  test "indexed equality is pushed down, the rest is residual", context do
    tenant_id = context[:tenant_id]

    plan = plan("select id, name from #{tenant_id}.users where name = 'Alice' and notes = 'x';")

    assert {:index_scan, %Ecto.Query{wheres: [%{expr: {:==, [], [_, "Alice"]}}]}, _opts} =
             plan.access

    assert [{:filter, [{:cmp, :==, :notes, "x"}]}, {:project, [:id, :name]}] = plan.ops
  end

  test "unindexed constraint goes straight to a range scan", context do
    tenant_id = context[:tenant_id]

    plan = plan("select id from #{tenant_id}.users where notes = 'foobar';")

    assert {:pk_range, %Ecto.Query{wheres: []}, nil, nil, _opts} = plan.access
    assert [{:filter, [{:cmp, :==, :notes, "foobar"}]}, {:project, [:id]}] = plan.ops
  end

  test "order matching an index is served natively by the adapter", context do
    tenant_id = context[:tenant_id]

    plan = plan("select id, name from #{tenant_id}.users order by name desc limit 2;")

    assert {:index_scan, query = %Ecto.Query{}, _opts} = plan.access
    assert [%Ecto.Query.ByExpr{expr: [desc: _]}] = query.order_bys
    assert %Ecto.Query.LimitExpr{expr: 2} = query.limit
    assert plan.ops == []
  end

  test "indexed range with order on the same field is served natively", context do
    tenant_id = context[:tenant_id]

    plan =
      plan(
        "select id, name from #{tenant_id}.users where name between 'A' and 'D' order by name desc limit 2;"
      )

    assert {:index_scan, query = %Ecto.Query{wheres: [_]}, _opts} = plan.access
    assert [%Ecto.Query.ByExpr{}] = query.order_bys
    assert plan.ops == []
  end

  test "order on a non-indexed field is sorted by efsql", context do
    tenant_id = context[:tenant_id]

    plan = plan("select id from #{tenant_id}.users order by id desc limit 2;")

    assert {:pk_range, query = %Ecto.Query{}, nil, nil, _opts} = plan.access
    assert query.order_bys == []
    assert query.limit == nil
    assert [{:sort, [desc: :id]}, {:limit, 2}] = plan.ops
  end

  test "in on an indexed field fans out to a union", context do
    tenant_id = context[:tenant_id]

    plan = plan("select id, name from #{tenant_id}.users where name in ('Alice', 'Bob');")

    assert {:union, [{:index_scan, _, _}, {:index_scan, _, _}]} = plan.access
  end

  test "in on the primary key fans out to a union of pk ranges", context do
    tenant_id = context[:tenant_id]

    plan = plan("select id from #{tenant_id}.users where _ in ('0001', '0003');")

    assert {:union, [{:pk_range, _, "0001", "0001", _}, {:pk_range, _, "0003", "0003", _}]} =
             plan.access
  end

  test "in on an unindexed field is filtered over a scan", context do
    tenant_id = context[:tenant_id]

    plan = plan("select id from #{tenant_id}.users where notes in ('foobar', 'nope');")

    assert {:pk_range, _, nil, nil, _opts} = plan.access
    assert [{:filter, [{:in, :notes, ["foobar", "nope"]}]}, {:project, [:id]}] = plan.ops
  end

  test "residual filtering disables limit pushdown", context do
    tenant_id = context[:tenant_id]

    plan = plan("select id from #{tenant_id}.users where notes = 'foobar' limit 1;")

    assert {:pk_range, %Ecto.Query{limit: nil}, nil, nil, _opts} = plan.access
    assert {:limit, 1} in plan.ops
  end

  test "single-value in plans as an equality", context do
    tenant_id = context[:tenant_id]

    plan = plan("select id, name from #{tenant_id}.users where name in ('Alice');")

    assert {:index_scan, %Ecto.Query{wheres: [%{expr: {:==, [], [_, "Alice"]}}]}, _opts} =
             plan.access
  end
end
