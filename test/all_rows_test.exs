defmodule EfsqlTest.Integration.SelectAllRows do
  use EfsqlTest.Case, async: true

  test "select id column", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001"],
             [id: "0002"],
             [id: "0003"]
           ] =
             Efsql.all("select id from #{tenant_id}.users;")
             |> Enum.map(&Map.to_list/1)
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
             |> Enum.map(&Map.to_list/1)
  end

  test "select name column", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001", name: "Alice"],
             [id: "0002", name: "Bob"],
             [id: "0003", name: "Charles"]
           ] =
             Efsql.all("select id, name from #{tenant_id}.users;")
             |> Enum.map(&Map.to_list/1)
  end

  test "select 3 columns", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001", name: "Alice", notes: "Lorem ipsum"],
             [id: "0002", name: "Bob", notes: "foobar"],
             [id: "0003", name: "Charles", notes: nil]
           ] =
             Efsql.all("select id, name, notes from #{tenant_id}.users;")
             |> Enum.map(&Map.to_list/1)
  end
end
