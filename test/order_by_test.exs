defmodule EfsqlTest.Integration.OrderBy do
  use EfsqlTest.Case, async: true

  test "order by ascending", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Alice"}, %{name: "Bob"}, %{name: "Charles"}] =
             Efsql.all("select id, name from #{tenant_id}.users order by name;")
  end

  test "order by descending", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Charles"}, %{name: "Bob"}, %{name: "Alice"}] =
             Efsql.all("select id, name from #{tenant_id}.users order by name desc;")
  end

  test "order by with limit applies limit after sorting", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Charles"}, %{name: "Bob"}] =
             Efsql.all("select id, name from #{tenant_id}.users order by name desc limit 2;")
  end

  test "order by field not in select projects it away", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0003"}, %{id: "0002"}, %{id: "0001"}] =
             rows = Efsql.all("select id from #{tenant_id}.users order by name desc;")

    for row <- rows do
      assert Map.keys(row) == [:id]
    end
  end

  # Note byte-wise string order: "Lorem ipsum" < "foobar" (uppercase sorts first)
  test "nulls sort last ascending", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Alice"}, %{name: "Bob"}, %{name: "Charles"}] =
             Efsql.all("select id, name, notes from #{tenant_id}.users order by notes;")
  end

  test "nulls sort first descending", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Charles"}, %{name: "Bob"}, %{name: "Alice"}] =
             Efsql.all("select id, name, notes from #{tenant_id}.users order by notes desc;")
  end

  test "order by two fields", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0003"}, %{id: "0002"}, %{id: "0001"}] =
             Efsql.all("select id, notes from #{tenant_id}.users order by notes desc, id asc;")
  end

  test "order by pk descending with limit", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0003"}, %{id: "0002"}] =
             Efsql.all("select id from #{tenant_id}.users order by id desc limit 2;")
  end

  test "order by combined with a where clause", context do
    tenant_id = context[:tenant_id]

    assert [%{name: "Bob"}, %{name: "Alice"}] =
             Efsql.all(
               "select id, name from #{tenant_id}.users where name between 'A' and 'C' order by name desc;"
             )
  end
end
