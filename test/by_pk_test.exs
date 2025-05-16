defmodule EfsqlTest.Integration.SelectByPk do
  use EfsqlTest.Case, async: true

  test "select by pk equals", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001", name: "Alice", notes: "Lorem ipsum"]
           ] =
             Efsql.all("select id, name, notes from #{tenant_id}.users where id = '0001';")
  end

  test "select by pk between", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001", name: "Alice", notes: "Lorem ipsum"],
             [id: "0002", name: "Bob", notes: "foobar"]
           ] =
             Efsql.all(
               "select id, name, notes from #{tenant_id}.users where id >= '0001' and id <= '0002';"
             )
  end
end
