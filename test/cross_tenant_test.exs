defmodule EfsqlTest.Integration.CrossTenant do
  use EfsqlTest.Case, async: true

  alias Efsql.Exception.Unsupported
  alias Efsql.Physical.Plan
  alias EctoFoundationDB.Sandbox
  alias EfsqlTest.Repo
  alias EfsqlTest.User

  # The case's tenant holds Alice, Bob and Charles; this adds a second with
  # Dora and Eve. Other tests' tenants share the storage id, so every query
  # names its two tenants with a condition on _tenant.
  setup context do
    other = "t_" <> String.replace(Ecto.UUID.generate(), "-", "")
    tenant = Sandbox.checkout(Repo, other, [])

    Repo.transaction(
      fn ->
        Repo.insert(%User{id: "0004", name: "Dora", notes: "foobar"})
        Repo.insert(%User{id: "0005", name: "Eve"})
      end,
      prefix: tenant
    )

    on_exit(fn -> Sandbox.checkin(Repo, other) end)

    both = "_tenant in ('#{context[:tenant_id]}', '#{other}')"
    {:ok, other: other, both: both}
  end

  test "one row per tenant with GROUP BY _tenant", context do
    rows =
      Efsql.all(
        "select _tenant, count(*) as n from *.users where #{context[:both]} group by _tenant;"
      )

    assert Enum.sort(rows) ==
             Enum.sort([%{_tenant: context[:tenant_id], n: 3}, %{_tenant: context[:other], n: 2}])
  end

  test "ORDER BY and LIMIT apply to all the tenants' rows together", context do
    assert [%{name: "Eve"}, %{name: "Dora"}, %{name: "Charles"}] =
             Efsql.all(
               "select name, _tenant from *.users where #{context[:both]} " <>
                 "order by name desc limit 3;"
             )
  end

  test "every row says which tenant it came from", context do
    rows = Efsql.all("select * from *.users where #{context[:both]};")

    assert rows |> Enum.map(& &1._tenant) |> Enum.frequencies() == %{
             context[:tenant_id] => 3,
             context[:other] => 2
           }
  end

  test "an aggregate over every tenant", context do
    assert [%{n: 5, "max(name)": "Eve"}] =
             Efsql.all("select count(*) as n, max(name) from *.users where #{context[:both]};")
  end

  test "WHERE applies within each tenant", context do
    rows =
      Efsql.all("select _tenant, name from *.users where #{context[:both]} and notes = 'foobar';")

    assert Enum.sort_by(rows, & &1.name) == [
             %{_tenant: context[:tenant_id], name: "Bob"},
             %{_tenant: context[:other], name: "Dora"}
           ]
  end

  test "a condition on _tenant chooses the tenants to read", context do
    {%Plan{access: {:fan_out, per_tenant}}, rows, _tenants} =
      Efsql.qall("select name from *.users where _tenant = '#{context[:other]}';")

    assert [{other, _plan}] = per_tenant
    assert other == context[:other]
    assert Enum.sort_by(rows, & &1.name) == [%{name: "Dora"}, %{name: "Eve"}]

    assert {%Plan{access: {:fan_out, []}}, [], _} =
             Efsql.qall("select name from *.users where _tenant = 'no-such-tenant';")
  end

  test "each tenant keeps its index pushdown", context do
    {%Plan{access: {:fan_out, per_tenant}, ops: ops}, rows, _tenants} =
      Efsql.qall("select _tenant, name from *.users where #{context[:both]} and name = 'Dora';")

    for {_tenant, %Plan{access: access}} <- per_tenant do
      assert {:index_scan, %Ecto.Query{wheres: [_]}, _opts} = access
    end

    assert ops == []
    assert rows == [%{_tenant: context[:other], name: "Dora"}]
  end

  test "more tenants than the limit is refused", context do
    assert_raise Unsupported, ~r/would read 2 tenants, more than the limit of 1/, fn ->
      Efsql.all("select name from *.users where #{context[:both]};", max_tenants: 1)
    end
  end

  test "tenants can be read in batches, one transaction each", context do
    sql =
      "select _tenant, count(*) as n, max(name) as last from *.users " <>
        "where #{context[:both]} group by _tenant order by last desc;"

    # grouping and ordering see every tenant's rows together
    expected = [
      %{_tenant: context[:other], n: 2, last: "Eve"},
      %{_tenant: context[:tenant_id], n: 3, last: "Charles"}
    ]

    {plan, ^expected, _tenants} = Efsql.qall(sql)
    assert Efsql.Fanout.transactions(plan) == 1

    # One tenant per batch, and no tenant limit: each transaction reads one.
    # The same result whether the batches are read one at a time or together.
    for concurrency <- [1, 2] do
      options = [tenant_batch: 1, max_tenants: 1, batch_concurrency: concurrency]

      {%Plan{access: {:batches, batches, ^concurrency}} = plan, rows, _tenants} =
        Efsql.qall(sql, options)

      assert [{:fan_out, [_]}, {:fan_out, [_]}] = batches
      assert Efsql.Fanout.transactions(plan) == 2
      assert rows == expected
    end
  end

  test "ORDER BY ... LIMIT and a plain LIMIT across batches", context do
    batched = [tenant_batch: 1, max_tenants: 1, batch_concurrency: 2]

    top = "select name from *.users where #{context[:both]} order by name desc limit 2;"
    assert {_plan, [%{name: "Eve"}, %{name: "Dora"}], _} = Efsql.qall(top, batched)

    # without ORDER BY any 2 rows will do, and reading stops once it has them
    any = "select name from *.users where #{context[:both]} limit 2;"
    assert {_plan, [_, _], _} = Efsql.qall(any, batched)
  end

  test "a read too old for its transaction fails at once instead of retrying", context do
    sql = "select name from *.users where #{context[:both]};"

    # Open the tenants first, so that only the reads run in the transaction below.
    {_plan, _rows, tenants} = Efsql.qall(sql)

    db = Ecto.Adapters.FoundationDB.db(Efsql.Repo)
    attempts = :counters.new(1, [])

    # A read version far older than FoundationDB keeps makes every read fail
    # with transaction_too_old, which erlfdb would retry. The query joins this
    # transaction; if the error reached the retry loop, this function would
    # run again (and again).
    assert_raise Unsupported,
                 ~r/read too much to finish in one transaction across 2 tenants/,
                 fn ->
                   Ecto.Adapters.FoundationDB.transactional(db, fn tx ->
                     :counters.add(attempts, 1, 1)
                     :erlfdb.set_read_version(tx, 1)
                     Efsql.qall(sql, [], tenants)
                   end)
                 end

    assert :counters.get(attempts, 1) == 1
  end
end
