defmodule EfsqlTest.Integration.SelectByIndex do
  use EfsqlTest.Case, async: true

  test "select by index equals", context do
    tenant_id = context[:tenant_id]

    assert [[id: "0001", name: "Alice", notes: "Lorem ipsum"]] =
             Efsql.all("select id, name, notes from #{tenant_id}.users where name = 'Alice';")
             |> Enum.map(&Map.to_list/1)
  end

  test "select by index between", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001", name: "Alice", notes: "Lorem ipsum"],
             [id: "0002", name: "Bob", notes: "foobar"]
           ] =
             Efsql.all(
               "select id, name, notes from #{tenant_id}.users where name > 'A' and name < 'C';"
             )
             |> Enum.map(&Map.to_list/1)
  end
end
