defmodule EfsqlTest.Integration.Null do
  use EfsqlTest.Case, async: true

  test "is null matches a field that was never set", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0003"}] =
             Efsql.all("select id from #{tenant_id}.users where notes is null;")
  end

  test "is not null", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0001"}, %{id: "0002"}] =
             Efsql.all("select id from #{tenant_id}.users where notes is not null;")
             |> Enum.sort_by(& &1.id)
  end

  test "is not null combined with an indexed equality", context do
    tenant_id = context[:tenant_id]

    assert [] =
             Efsql.all(
               "select id from #{tenant_id}.users where name = 'Charles' and notes is not null;"
             )

    assert [%{id: "0001"}] =
             Efsql.all(
               "select id from #{tenant_id}.users where name = 'Alice' and notes is not null;"
             )
  end
end
