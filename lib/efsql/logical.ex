defmodule Efsql.Logical do
  @moduledoc """
  The logical query representation: what the SQL statement asks for,
  independent of how it will be executed.

  Its predicates are an implicitly AND-ed list of `Efsql.Predicate`s.

  The primary key is the pseudo-field `:_`. A query across every tenant of
  a storage id (`*.table`) also has `:_tenant`, the tenant's name, which
  isn't stored: predicates on it choose the tenants to read, and the
  executor adds it to each row.

  A grouped query (`GROUP BY`, or any aggregate) has `group_by` set to its
  key fields (`[]` for one group over every row) and `aggregates` to
  `{output_name, function, field | :star}`, `function` one of `:count`,
  `:sum`, `:min`, `:max`, `:avg`. Its `projection` and `order` then name
  output columns: group fields and aggregate names.

  `Efsql.Rewrite` normalizes a logical query, `Efsql.Planner` turns it into
  an `Efsql.Physical.Plan`.
  """

  defmodule Select do
    defstruct source: nil,
              # tenant name, or {storage_id, tenant_name}, as written in the SQL;
              # {:all_tenants, storage_id | nil} for `*.table`, every tenant of
              # a storage id
              prefix: nil,
              # the opened EctoFoundationDB.Tenant, resolved before planning
              tenant: nil,
              # :star | [field :: atom]
              projection: :star,
              predicates: [],
              # [{:asc | :desc, field}]
              order: [],
              limit: nil,
              # nil, or the GROUP BY fields of a grouped query
              group_by: nil,
              # [{output_name :: atom, function :: atom, field :: atom | :star}]
              aggregates: []
  end
end
