defmodule EfsqlTest.Integration.Discover do
  use EfsqlTest.Case, async: true

  alias Efsql.Discover

  test "sources enumerates distinct sources from the keyspace", context do
    tenant = context[:tenant]

    assert Discover.sources(tenant, EfsqlTest.Repo) == ["users"]
  end

  test "schema is inferred from sampled rows", context do
    tenant = context[:tenant]

    schema = Discover.schema(tenant, "users")

    assert schema.sampled == 3
    assert schema.pk == :string

    by_name = Map.new(schema.fields, &{&1.name, &1})
    assert by_name[:name].presence == 1.0
    assert_in_delta by_name[:notes].presence, 2 / 3, 0.01
    assert by_name[:name].types == %{string: 3}
    assert "Alice" in by_name[:name].examples

    assert [%{name: :users_name_index, fields: [:name]}] = schema.indexes
  end

  test "schema cache round-trips", context do
    tenant = context[:tenant]
    schema = Discover.schema(tenant, "users")

    key = {"test", "cache", context[:tenant_id], "users"}
    assert :ok = Discover.cache_put(key, schema)
    assert {:ok, ^schema} = Discover.cache_get(key)
  end

  test "session qall runs unqualified statements against the active tenant", context do
    tenant = context[:tenant]

    assert {_plan, [%{name: "Alice"}], _tenants} =
             Efsql.Tui.Session.qall(
               "select id, name from users where name = 'Alice';",
               %{tenant: tenant, tenants: %{}}
             )
  end
end
