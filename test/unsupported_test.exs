defmodule EfsqlTest.Integration.Unsupported do
  use EfsqlTest.Case, async: true

  alias Efsql.Exception.Unsupported

  test "* raises", context do
    tenant_id = context[:tenant_id]

    assert_raise(Unsupported, ~r/'*' is not supported/, fn ->
      Efsql.all("select * from #{tenant_id}.users;")
    end)
  end
end
