defmodule EfsqlTest.Integration.Unsupported do
  use EfsqlTest.Case, async: true

  alias Efsql.Exception.Unsupported

  test "select * raises for index queries", context do
    tenant_id = context[:tenant_id]

    assert_raise(Unsupported, ~r/SELECT \* is not supported for index queries/, fn ->
      Efsql.all("select * from #{tenant_id}.users where name = 'Alice';")
    end)
  end
end
