defmodule Efsql.Tui.Session do
  @moduledoc """
  Session-aware query execution: statements without a tenant qualifier run
  against the session's active tenant, so `select id from users;` works
  once a tenant is activated in the Navigator. Tenant-qualified statements
  behave exactly as in the line CLI.
  """

  def qall(_sql, %{tenant: nil}) do
    raise Efsql.Exception.Unsupported,
          "no active tenant — qualify the table (tenant.table) or pick a tenant in the navigator"
  end

  def qall(sql, %{tenant: tenant, tenants: tenants}) do
    {:ok, context, tokens} = SQL.Lexer.lex(sql)
    {:ok, _context, parsed} = SQL.Parser.parse(tokens, context)
    logical = %Efsql.Logical.Select{} = Efsql.Parser.to_logical(parsed)

    {logical, tenants} =
      case logical.prefix do
        nil -> {%{logical | tenant: tenant}, tenants}
        _ -> Efsql.resolve_tenant(logical, tenants)
      end

    plan = logical |> Efsql.Rewrite.normalize() |> Efsql.Planner.plan([])
    {plan, Efsql.Executor.run(plan), tenants}
  end
end
