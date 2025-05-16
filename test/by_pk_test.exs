defmodule EfsqlTest.Integration.SelectByPk do
  use EfsqlTest.Case, async: true

  # Querying primary key via
  # 1. _ identifier
  # 2. 'primary key' keywords

  test "select by pk equals", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001", name: "Alice", notes: "Lorem ipsum"]
           ] =
             Efsql.all("select id, name, notes from #{tenant_id}.users where _ = '0001';")
             |> Enum.map(&Map.to_list/1)
  end

  test "select by pk between", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001", name: "Alice", notes: "Lorem ipsum"],
             [id: "0002", name: "Bob", notes: "foobar"]
           ] =
             Efsql.all(
               "select id, name, notes from #{tenant_id}.users where primary key >= '0001' and primary key <= '0002';"
             )
             |> Enum.map(&Map.to_list/1)
  end
end
