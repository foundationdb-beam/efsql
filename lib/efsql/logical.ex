defmodule Efsql.Logical do
  @moduledoc """
  The logical query representation: what the SQL statement asks for,
  independent of how it will be executed.

  Predicates are an implicitly AND-ed list of:

    * `{:cmp, op, field, value}` — op in `:== :> :>= :< :<=`
    * `{:range, field, {lower_op, value}, {upper_op, value}}` — a two-sided
      bound, `lower_op` in `:> :>=`, `upper_op` in `:< :<=`
    * `{:like, field, pattern}` / `{:not_like, field, pattern}`
    * `{:in, field, values}`

  The primary key is the pseudo-field `:_`.

  `Efsql.Rewrite` normalizes a logical query, `Efsql.Planner` turns it into
  an `Efsql.Physical.Plan`.
  """

  defmodule Select do
    defstruct source: nil,
              # tenant name, or {storage_id, tenant_name}, as written in the SQL
              prefix: nil,
              # the opened EctoFoundationDB.Tenant, resolved before planning
              tenant: nil,
              # :star | [field :: atom]
              projection: :star,
              predicates: [],
              # [{:asc | :desc, field}]
              order: [],
              limit: nil
  end

  def predicate_field({:cmp, _op, field, _value}), do: field
  def predicate_field({:range, field, _lower, _upper}), do: field
  def predicate_field({:like, field, _pattern}), do: field
  def predicate_field({:not_like, field, _pattern}), do: field
  def predicate_field({:in, field, _values}), do: field
end
