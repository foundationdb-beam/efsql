defmodule EfsqlTest.Integration.Timestamp do
  use EfsqlTest.Case, async: true

  test "timestamp range on a naive_datetime field", context do
    tenant_id = context[:tenant_id]

    assert [_, _, _] =
             Efsql.all(
               "select id from #{tenant_id}.users where inserted_at > '2000-01-01'::timestamp;"
             )

    assert [] =
             Efsql.all(
               "select id from #{tenant_id}.users where inserted_at < '2000-01-01'::timestamp;"
             )
  end

  test "timestamp equality ignores precision", context do
    tenant_id = context[:tenant_id]

    [%{inserted_at: inserted_at} | _] =
      Efsql.all("select id, inserted_at from #{tenant_id}.users where _ = '0001';")

    literal = inserted_at |> NaiveDateTime.add(0, :microsecond) |> NaiveDateTime.to_iso8601()

    assert [%{id: "0001"}] =
             Efsql.all(
               "select id from #{tenant_id}.users where _ = '0001' and inserted_at = '#{literal}'::timestamp;"
             )
  end
end
