defmodule EfsqlTest.Integration.In do
  use EfsqlTest.Case, async: true

  test "in on primary key fans out to concurrent gets", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0001", name: "Alice"}, %{id: "0003", name: "Charles"}] =
             Efsql.all("select id, name from #{tenant_id}.users where _ in ('0001', '0003');")
             |> Enum.sort_by(& &1.id)
  end

  test "in on indexed field fans out to concurrent index queries", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Alice"}, %{name: "Bob"}] =
             Efsql.all("select id, name from #{tenant_id}.users where name in ('Alice', 'Bob');")
             |> Enum.sort_by(& &1.name)
  end

  test "in with values that do not exist", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Alice"}] =
             Efsql.all(
               "select id, name from #{tenant_id}.users where name in ('Alice', 'Nobody');"
             )
  end

  test "in combined with residual filter", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0002"}] =
             Efsql.all(
               "select id from #{tenant_id}.users where name in ('Alice', 'Bob') and notes like '%bar%';"
             )
  end

  test "in combined with order by", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Bob"}, %{name: "Alice"}] =
             Efsql.all(
               "select id, name from #{tenant_id}.users where name in ('Alice', 'Bob') order by name desc;"
             )
  end

  test "in on unindexed field falls back to scan", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0002"}] =
             Efsql.all("select id from #{tenant_id}.users where notes in ('foobar', 'nope');")
  end

  test "in with a single value", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Charles"}] =
             Efsql.all("select id, name from #{tenant_id}.users where name in ('Charles');")
  end
end
