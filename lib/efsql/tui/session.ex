defmodule Efsql.Tui.Session do
  @moduledoc """
  Session-aware query execution: statements without a tenant qualifier run
  against the session's active tenant, so `select id from users;` works
  once a tenant is activated in the Navigator, and `*.users` reads every
  tenant of the active storage id. Tenant-qualified statements behave
  exactly as in the line CLI.
  """

  alias Efsql.Logical

  def qall(sql, session) do
    sql
    |> Efsql.Parser.sql_to_logical()
    |> in_session(session)
    |> Efsql.run_logical(options(session), session.tenants)
  end

  defp options(%{tenant_batch: n}) when is_integer(n), do: [tenant_batch: n]
  defp options(_session), do: []

  defp in_session(%Logical.Select{prefix: {:all_tenants, nil}} = logical, session),
    do: %Logical.Select{logical | prefix: {:all_tenants, session[:storage_id]}}

  defp in_session(%Logical.Select{prefix: nil}, %{tenant: nil}) do
    raise Efsql.Exception.Unsupported,
          "no active tenant — qualify the table (tenant.table) or pick a tenant in the navigator"
  end

  defp in_session(%Logical.Select{prefix: nil} = logical, %{tenant: tenant}),
    do: %Logical.Select{logical | tenant: tenant}

  defp in_session(logical, _session), do: logical
end
