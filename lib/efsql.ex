defmodule Efsql do
  @moduledoc """
  SQL frontend for EctoFoundationDB.

  A statement flows through the textbook pipeline:

      SQL text
        |> Efsql.Parser.to_logical()     # parse tree -> Efsql.Logical.Select
        |> resolve tenant
        |> Efsql.Rewrite.normalize()     # rewrite passes
        |> Efsql.Planner.plan()          # access-path selection -> Efsql.Physical.Plan
        |> Efsql.Executor.run()          # adapter pull + operator pipeline
  """

  import Ecto.Query

  def lex_and_parse(sql) do
    {:ok, context, tokens} = SQL.Lexer.lex(sql)
    SQL.Parser.parse(tokens, context)
  end

  def hello() do
    tenant = EctoFoundationDB.Tenant.open!(Efsql.Repo, "localhost")

    query = from(s in "secrets", select: [id: s.id, iv: s.iv])
    r1 = Efsql.Repo.all(query, prefix: tenant)

    r2 = all("select id, iv from localhost.secrets;")

    {r1, r2}
  end

  def all(sql, options \\ []) do
    {_, result, _tenants} = qall(sql, options)
    result
  end

  def qall(sql, options \\ [], tenants \\ %{}) do
    {logical, tenants} = sql_to_logical(sql, tenants)
    plan = logical |> Efsql.Rewrite.normalize() |> Efsql.Planner.plan(options)
    {plan, Efsql.Executor.run(plan), tenants}
  end

  def stream(sql) do
    {logical, _tenants} = sql_to_logical(sql)
    query = logical |> Efsql.Rewrite.normalize() |> Efsql.Planner.to_ecto_query()
    {query, Efsql.Repo.stream(query)}
  end

  def sql_to_logical(sql, tenants \\ %{}) do
    {:ok, context, tokens} = SQL.Lexer.lex(sql)
    {:ok, _context, parsed} = SQL.Parser.parse(tokens, context)
    logical = %Efsql.Logical.Select{} = Efsql.Parser.to_logical(parsed)
    resolve_tenant(logical, tenants)
  end

  def resolve_tenant(%Efsql.Logical.Select{} = logical, tenants) do
    {tenant_name, open_opts} =
      case logical.prefix do
        {storage_id, tenant_name} -> {tenant_name, [storage_id: storage_id]}
        nil -> raise "Tenant required"
        tenant_name -> {tenant_name, []}
      end

    cache_key = {tenant_name, open_opts[:storage_id]}

    {tenant, tenants} =
      case Map.fetch(tenants, cache_key) do
        {:ok, cached} ->
          {cached, tenants}

        :error ->
          unless EctoFoundationDB.Tenant.exists?(Efsql.Repo, tenant_name) do
            raise Efsql.Exception.Unsupported, "Tenant '#{tenant_name}' does not exist"
          end

          # migrate: false keeps this read-only. Tenant.open/3 already requires
          # the tenant to exist (only open!/3 creates), so with the migration
          # step skipped efsql never writes to the database it is exploring.
          t = EctoFoundationDB.Tenant.open(Efsql.Repo, tenant_name, [migrate: false] ++ open_opts)
          {t, Map.put(tenants, cache_key, t)}
      end

    {%Efsql.Logical.Select{logical | tenant: tenant}, tenants}
  end
end
