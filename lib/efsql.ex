defmodule Efsql do
  import Ecto.Query

  def all(sql) do
    query = sql_to_ecto_query(sql)
    Efsql.Repo.all(query)
  end

  def stream(sql) do
    query = sql_to_ecto_query(sql)
    {query, Efsql.Repo.stream(query)}
  end

  def sql_to_ecto_query(sql) do
    {:ok, _opts, _, _, _, _, tokens} = SQL.Lexer.lex(sql, {1, 0, nil}, 0, format: true)
    parsed = SQL.Parser.parse(tokens)
    query = Efsql.SqlToEctoQuery.to_ecto_query(SQL.to_query(parsed))
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
