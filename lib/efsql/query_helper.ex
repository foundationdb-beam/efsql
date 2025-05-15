defmodule Efsql.QueryHelper do
  def get_select_fields(query) do
    %Ecto.Query{
      select: %Ecto.Query.SelectExpr{
        fields: fields
      }
    } = query

    fields
  end
end
