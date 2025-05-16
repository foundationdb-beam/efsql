defmodule Efsql.QueryHelper do
  def get_select_fields(query) do
    %Ecto.Query{
      select: %Ecto.Query.SelectExpr{
        take: %{0 => {:any, fields}}
      }
    } = query

    fields
  end
end
