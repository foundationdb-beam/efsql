defmodule EfsqlTest.IntegrationUnsupported do
  use EfsqlTest.Case, async: true

  test "* raises", context do
    tenant_id = context[:tenant_id]

    assert_raise(RuntimeError, ~r/'*' is not supported/, fn ->
      Efsql.all("select * from #{tenant_id}.users;")
    end)
  end
end

defmodule EfsqlTest.IntegrationSelectAllRows do
  use EfsqlTest.Case, async: true

  test "select id column", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001"],
             [id: "0002"],
             [id: "0003"]
           ] =
             Efsql.all("select id from #{tenant_id}.users;")
  end

  test "select with double-quote tenant id", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001"],
             [id: "0002"],
             [id: "0003"]
           ] =
             Efsql.all("""
             select id from "#{tenant_id}".users;
             """)
  end

  test "select name column", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001", name: "Alice"],
             [id: "0002", name: "Bob"],
             [id: "0003", name: "Charles"]
           ] =
             Efsql.all("select id, name from #{tenant_id}.users;")
  end

  test "select 3 columns", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001", name: "Alice", notes: "Lorem ipsum"],
             [id: "0002", name: "Bob", notes: "foobar"],
             [id: "0003", name: "Charles", notes: nil]
           ] =
             Efsql.all("select id, name, notes from #{tenant_id}.users;")
  end
end

defmodule EfsqlTest.IntegrationSelectByIndex do
  use EfsqlTest.Case, async: true
end

defmodule EfsqlTest.IntegrationOrderBy do
  use EfsqlTest.Case, async: true
end
