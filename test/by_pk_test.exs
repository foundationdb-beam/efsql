defmodule EfsqlTest.Integration.SelectByPk do
  use EfsqlTest.Case, async: true

  # Querying _ via
  # 1. _ identifier
  # 2. '_' keywords

  # https://github.com/elixir-dbvisor/sql/issues/20
  test "select by pk equals", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001", name: "Alice", notes: "Lorem ipsum"]
           ] =
             Efsql.all("select id, name, notes from #{tenant_id}.users where _ = '0001';")
             |> Enum.map(&Map.to_list/1)
  end

  test "select by pk between inclusive", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001", name: "Alice", notes: "Lorem ipsum"],
             [id: "0002", name: "Bob", notes: "foobar"]
           ] =
             Efsql.all(
               "select id, name, notes from #{tenant_id}.users where _ >= '0001' and _ <= '0002';"
             )
             |> Enum.map(&Map.to_list/1)
  end

  test "select by pk between exclusive", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0002", name: "Bob", notes: "foobar"]
           ] =
             Efsql.all(
               "select id, name, notes from #{tenant_id}.users where _ > '0001' and _ < '0003';"
             )
             |> Enum.map(&Map.to_list/1)
  end

  test "select by pk greater", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001", name: "Alice", notes: "Lorem ipsum"],
             [id: "0002", name: "Bob", notes: "foobar"],
             [id: "0003", name: "Charles", notes: nil]
           ] =
             Efsql.all("select id, name, notes from #{tenant_id}.users where _ > '0';")
             |> Enum.map(&Map.to_list/1)
  end

  test "select by pk less", context do
    tenant_id = context[:tenant_id]

    assert [
             [id: "0001", name: "Alice", notes: "Lorem ipsum"]
           ] =
             Efsql.all("select id, name, notes from #{tenant_id}.users where _ < '0002';")
             |> Enum.map(&Map.to_list/1)
  end
end
