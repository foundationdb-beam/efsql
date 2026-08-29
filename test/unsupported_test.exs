defmodule EfsqlTest.Integration.Unsupported do
  use EfsqlTest.Case, async: true

  alias Efsql.Exception.Unsupported

  test "order by the pk placeholder raises", context do
    tenant_id = context[:tenant_id]

    assert_raise(Unsupported, ~r/order by '_' is not supported/, fn ->
      Efsql.all("select id from #{tenant_id}.users order by _;")
    end)
  end

  test "multiple primary key constraints raise", context do
    tenant_id = context[:tenant_id]

    assert_raise(Unsupported, ~r/at most one constraint on the primary key/, fn ->
      Efsql.all("select id from #{tenant_id}.users where _ = '0001' and _ = '0002';")
    end)
  end
end
