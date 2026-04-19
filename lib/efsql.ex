defmodule Efsql do
  import Ecto.Query

  def lex_and_parse(sql) do
    {:ok, context, tokens} = SQL.Lexer.lex(sql)
    SQL.Parser.parse(tokens, context)
  end

  def hello() do
    tenant = EctoFoundationDB.Tenant.open!(Efsql.Repo, "localhost")

    query = from(s in "secrets", select: [id: s.id, iv: s.iv])
    r1 = Efsql.Repo.all(query, prefix: tenant)

    {query2, _tenants} =
      sql_to_ecto_query("""
      select id, iv from localhost.secrets;
      """)

    r2 = Efsql.Repo.all(query2)

    {r1, r2}
  end

  def all(sql, options \\ []) do
    {_, result, _tenants} = qall(sql, options)
    result
  end

  def qall(sql, options \\ [], tenants \\ %{}) do
    {query, tenants} = sql_to_ecto_query(sql, tenants)

    {call, result} =
      case Efsql.QuerySplitter.partition(query, options) do
        {:all_range, {query1, id_a, id_b, options}, _query2} ->
          {{:all_range, query1, id_a, id_b, options}, Efsql.Repo.all_range(query1, id_a, id_b, options)}

        {:all, {query1, options}, _query2} ->
          if is_nil(query1.select) do
            raise Efsql.Exception.Unsupported, "SELECT * is not supported for index queries"
          end
          {{:all, query1, options}, Efsql.Repo.all(query1, options)}
      end

    {call, result, tenants}
  end

  def stream(sql) do
    {query, _tenants} = sql_to_ecto_query(sql)
    {query, Efsql.Repo.stream(query)}
  end

  def sql_to_ecto_query(sql, tenants \\ %{}) do
    {:ok, context, tokens} = SQL.Lexer.lex(sql)
    {:ok, _context, parsed} = SQL.Parser.parse(tokens, context)
    query = %Ecto.Query{} = Efsql.SqlToEctoQuery.to_ecto_query(parsed)

    {tenant_name, open_opts} =
      case query.prefix do
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

          t = EctoFoundationDB.Tenant.open(Efsql.Repo, tenant_name, open_opts)
          {t, Map.put(tenants, cache_key, t)}
      end

    {%Ecto.Query{query | prefix: tenant}, tenants}
  end
end
