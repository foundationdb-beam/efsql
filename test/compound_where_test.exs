defmodule EfsqlTest.Integration.CompoundWhere do
  use EfsqlTest.Case, async: true

  test "indexed equality with residual filter", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0001", name: "Alice"}] =
             Efsql.all(
               "select id, name from #{tenant_id}.users where name = 'Alice' and notes = 'Lorem ipsum';"
             )

    assert [] =
             Efsql.all(
               "select id, name from #{tenant_id}.users where name = 'Alice' and notes = 'wrong';"
             )
  end

  test "indexed range with residual filter", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0002", name: "Bob"}] =
             Efsql.all(
               "select id, name from #{tenant_id}.users where name > 'A' and name < 'D' and notes = 'foobar';"
             )
  end

  test "primary key range with residual filter", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0002"}] =
             Efsql.all(
               "select id from #{tenant_id}.users where _ > '0000' and notes = 'foobar';"
             )
  end

  test "unindexed field falls back to scan with residual filter", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0002", name: "Bob"}] =
             Efsql.all("select id, name from #{tenant_id}.users where notes = 'foobar';")
  end

  test "residual filter field not in select is projected away", context do
    tenant_id = context[:tenant_id]

    assert [%{id: "0002"}] =
             rows = Efsql.all("select id from #{tenant_id}.users where notes = 'foobar';")

    for row <- rows do
      assert Map.keys(row) == [:id]
    end
  end

  test "null fields never match residual comparisons", context do
    tenant_id = context[:tenant_id]

    # Charles has notes = nil; SQL NULL semantics exclude him from any comparison
    assert [] = Efsql.all("select id from #{tenant_id}.users where notes < 'zzz' and name = 'Charles';")
  end
end
