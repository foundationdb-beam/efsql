defmodule Efsql.Physical do
  @moduledoc """
  The physical plan: one access node that pulls rows from the adapter, and a
  pipeline of operators `Efsql.Executor` applies to the pulled rows in order.

  Access nodes:

    * `{:pk_range, ecto_query, id_start, id_end, options}` — `Repo.all_range`;
      nil bounds are open (a full table scan is `{:pk_range, q, nil, nil, o}`)
    * `{:index_scan, ecto_query, options}` — `Repo.all`; the adapter selects
      the index, and serves any order_bys/limit left in the query natively
    * `{:all_from_source, ecto_query, options}` — `Repo.all_from_source`;
      same planning as `:index_scan` but returns full data objects, used for
      `select *` (the query carries no Ecto select)
    * `{:union, [access_node]}` — executes the nodes concurrently through the
      adapter's pipelining and concatenates their rows

  Operators:

    * `{:filter, [predicate]}` — `Efsql.Logical` predicates, SQL NULL semantics
    * `{:sort, [{:asc | :desc, field}]}` — NULLs last ascending, first descending
    * `{:limit, n}`
    * `{:project, [field]}` — trim rows to the requested fields
  """

  defmodule Plan do
    defstruct access: nil, ops: []
  end
end
