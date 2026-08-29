defmodule EfsqlTest.Integration.Like do
  use EfsqlTest.Case, async: true

  test "prefix like on indexed field", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0001", name: "Alice"}] =
             Efsql.all("select id, name from #{tenant_id}.users where name like 'Al%';")
  end

  test "prefix like matching multiple rows", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Alice"}] =
             Efsql.all("select id, name from #{tenant_id}.users where name like 'A%';")
  end

  test "suffix like requires a scan", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0001", name: "Alice"}] =
             Efsql.all("select id, name from #{tenant_id}.users where name like '%ce';")
  end

  test "infix like", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0001"}] =
             Efsql.all("select id from #{tenant_id}.users where notes like '%ipsum%';")
  end

  test "underscore wildcard with literal prefix", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0001", name: "Alice"}] =
             Efsql.all("select id, name from #{tenant_id}.users where name like 'Al_ce';")
  end

  test "like with no wildcard is an exact match", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0002"}] =
             Efsql.all("select id from #{tenant_id}.users where name like 'Bob';")
  end

  test "not like", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Bob"}, %{name: "Charles"}] =
             Efsql.all("select id, name from #{tenant_id}.users where name not like 'A%';")
  end

  test "like on a null field does not match", context do
    tenant_id = context[:tenant_id]

    # Charles has notes = nil, which matches neither like nor not like
    assert [%{id: "0001"}, %{id: "0002"}] =
             Efsql.all("select id from #{tenant_id}.users where notes like '%';")

    assert [] = Efsql.all("select id from #{tenant_id}.users where notes not like '%';")
  end

  test "regex metacharacters in pattern are literal", context do
    tenant_id = context[:tenant_id]

    assert [] = Efsql.all("select id from #{tenant_id}.users where name like '.*';")
  end

  test "like combined with order by", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Charles"}, %{name: "Alice"}] =
             Efsql.all(
               "select id, name from #{tenant_id}.users where name like '%l%' order by name desc;"
             )
  end
end
