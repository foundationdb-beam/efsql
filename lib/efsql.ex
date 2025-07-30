defmodule Efsql do
  import Ecto.Query

  def lex_and_parse(sql) do
    {:ok, context, tokens} = SQL.Lexer.lex(sql)
    SQL.Parser.parse(tokens, context)
  end

  def hello() do
    tenant = EctoFoundationDB.Tenant.open!(Efsql.Repo, "localhost")

    query = from(s in "secrets", select: [id: s.id, iv: s.iv])
    # IO.inspect(Map.drop(query, [:__struct__]))
    r1 = Efsql.Repo.all(query, prefix: tenant)

    query2 =
      sql_to_ecto_query("""
      select id, iv from localhost.secrets;
      """)

    r2 = Efsql.Repo.all(query2)

    {r1, r2}
  end

  def all(sql, options \\ []) do
    {_, result} = qall(sql, options)
    result
  end

  def qall(sql, options \\ []) do
    query = sql_to_ecto_query(sql)

    result =
      case Efsql.QuerySplitter.partition(query, options) do
        {:all_range, {query1, id_a, id_b, options}, _query2} ->
          # IO.inspect({query1, id_a, id_b, options})
          Efsql.Repo.all_range(query1, id_a, id_b, options)

        {:all, {query1, options}, _query2} ->
          # IO.inspect({query1, options})
          Efsql.Repo.all(query1, options)
      end

    {query, result}
  end

  def stream(sql) do
    query = sql_to_ecto_query(sql)
    {query, Efsql.Repo.stream(query)}
  end

  def sql_to_ecto_query(sql) do
    {:ok, context, tokens} = SQL.Lexer.lex(sql)
    {:ok, _context, parsed} = SQL.Parser.parse(tokens, context)
    [{:colon, _meta, query}, []] = parsed
    query = Efsql.SqlToEctoQuery.to_ecto_query(query)
    # IO.inspect(Map.drop(query, [:__struct__]))

    if is_nil(query.prefix) do
      raise """
      Tenant required
      """
    end

    tenant = EctoFoundationDB.Tenant.open!(Efsql.Repo, query.prefix)
    %Ecto.Query{query | prefix: tenant}
  end
end
