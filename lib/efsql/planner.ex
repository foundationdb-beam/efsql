defmodule Efsql.Planner do
  @moduledoc """
  Access-path selection: turns a normalized `Efsql.Logical.Select` into an
  `Efsql.Physical.Plan`.

  The planner reads the tenant's index metadata to decide the split
  deterministically: the predicates pushed to the adapter are exactly an
  equality-prefix of one index (optionally ending in a single range), and
  everything else becomes a `{:filter, ...}` operator.

  Ordering is pushed to the adapter when it can serve it natively — a single
  sort field that is either the schemaless primary key `:id` on a scan, or
  the first index field after the pushed equalities (the adapter then scans
  in sort order, honoring the limit without pulling the full result set).
  Otherwise a `{:sort, ...}` operator sorts after the pull.

  `select *` behaves like any field list: index-constrained queries are
  served by `Repo.all_from_source` (full data objects, no Ecto select
  required), pk constraints by `Repo.all_range`.

  A grouped query is planned as the plain query that pulls the fields its
  groups and aggregates read, so `WHERE` gets the same pushdown; grouping,
  ordering and the limit then run on the pulled rows.
  """

  alias Efsql.Exception.Unsupported
  alias Efsql.Logical
  alias Efsql.Physical.Plan
  alias Efsql.Predicate
  alias EctoFoundationDB.Layer.Metadata

  @pk_field :_

  def plan(%Logical.Select{group_by: group_by} = logical, options) when is_list(group_by) do
    {rows, ops} = split(logical)
    %Plan{} = plan = plan(rows, options)
    %Plan{plan | ops: plan.ops ++ ops, columns: columns(logical.projection)}
  end

  def plan(%Logical.Select{} = logical, options),
    do: %Plan{plan_rows(logical, options) | columns: columns(logical.projection)}

  @doc """
  Splits a query into the rows to read and the operators that must then
  run over all of them: the read carries only the filtering, and grouping,
  ordering, the limit and the final projection come after. A grouped
  query is always planned this way; a query across tenants is too, since
  its order and limit apply to the tenants' rows together.

  The read never asks for `:_tenant`, which isn't stored; the executor
  adds it to each row of a query across tenants.
  """
  def split(%Logical.Select{group_by: group_by} = logical) when is_list(group_by) do
    %Logical.Select{aggregates: aggregates, order: order, limit: limit} = logical
    read = Enum.uniq(group_by ++ for({_name, _fun, f} <- aggregates, f != :star, do: f))
    columns = group_by ++ Enum.map(aggregates, &elem(&1, 0))

    ops =
      [{:aggregate, group_by, aggregates}]
      |> append_if(order != [], {:sort, order})
      |> append_if(limit != nil, {:limit, limit})
      |> append_if(
        Enum.sort(columns) != Enum.sort(logical.projection),
        {:project, logical.projection}
      )

    {rows(logical, read), ops}
  end

  def split(%Logical.Select{projection: projection, order: order, limit: limit} = logical) do
    read =
      if projection == :star,
        do: :star,
        else: Enum.uniq(projection ++ Enum.map(order, fn {_dir, f} -> f end))

    ops =
      []
      |> append_if(order != [], {:sort, order})
      |> append_if(limit != nil, {:limit, limit})
      |> append_if(projection != :star and read != projection, {:project, projection})

    {rows(logical, read), ops}
  end

  defp rows(%Logical.Select{} = logical, read) do
    read = if read == :star, do: [], else: read -- [:_tenant]

    %Logical.Select{
      logical
      | projection: if(read == [], do: :star, else: read),
        order: [],
        limit: nil,
        group_by: nil,
        aggregates: []
    }
  end

  @doc "The result columns in select-list order, nil for `select *`."
  def columns(:star), do: nil
  def columns(fields), do: Enum.uniq(fields)

  defp plan_rows(%Logical.Select{} = logical, options) do
    %Logical.Select{predicates: preds, order: sort, projection: projection} = logical
    star? = projection == :star
    {pks, ins, pushables, residuals} = classify(preds)

    indexes =
      if pks == [] and (ins != [] or pushables != [] or sort != []) do
        load_indexes(logical)
      else
        []
      end

    cond do
      pks != [] ->
        [pk_pred | extra_pks] = pks

        if extra_pks != [] do
          raise Unsupported, "at most one constraint on the primary key '_' is supported"
        end

        residual = pushables ++ ins ++ residuals
        assemble(logical, options, &pk_access(pk_pred, &1, &2), residual, true)

      ins != [] ->
        plan_in(logical, options, ins, pushables ++ residuals, indexes, star?)

      true ->
        plan_select(logical, options, pushables, residuals, indexes, star?)
    end
  end

  # -- SELECT planning --

  defp plan_select(logical, options, pushables, residuals, indexes, star?) do
    {idx, pushed, rest} = choose_index(indexes, pushables)
    residual = rest ++ residuals

    cond do
      native_sort?(logical.order, residual, idx, pushed, indexes) ->
        native_sorted_plan(logical, options, pushed, star?)

      pushed != [] ->
        assemble(
          logical,
          options,
          fn q, opts -> scan_node(star?, put_wheres(q, pushed), opts) end,
          residual,
          true
        )

      true ->
        full_scan(logical, options, residual)
    end
  end

  # Repo.all needs an Ecto select, which a schemaless source can only
  # express as an explicit field list; star queries use Repo.all_from_source
  # instead, which returns full data objects.
  defp scan_node(true = _star?, query, options), do: {:all_from_source, query, options}
  defp scan_node(false = _star?, query, options), do: {:index_scan, query, options}

  # Adapter-native ordering: single sort field, nothing filtered after the
  # pull (else the pushed limit would be wrong), and a sort field the scan
  # actually delivers in order — the schemaless primary key `:id` or an
  # index's first field on an unconstrained scan, or the first index field
  # not pinned by an equality on an index scan.
  defp native_sort?([{_dir, field}], [] = _residual, idx, pushed, indexes) do
    if idx == nil do
      field == :id or Enum.any?(indexes, fn ix -> List.first(ix[:fields]) == field end)
    else
      equal_fields = for p <- pushed, Predicate.equality?(p), do: Predicate.field(p)
      List.first(idx[:fields] -- equal_fields) == field
    end
  end

  defp native_sort?(_sort, _residual, _idx, _pushed, _indexes), do: false

  defp native_sorted_plan(logical, options, pushed, star?) do
    take = if logical.projection == :star, do: nil, else: logical.projection

    query =
      base_query(logical)
      |> put_select(take)
      |> put_wheres(pushed)
      |> put_order(logical.order)
      |> put_limit(logical.limit)

    %Plan{access: scan_node(star?, query, options), ops: []}
  end

  # -- index selection --

  # Mirrors the adapter's Default-indexer rules: the pushed predicates must
  # be equalities on a leading prefix of the index fields, optionally
  # followed by one range on the next field. Picks the index that absorbs
  # the most predicates.
  defp choose_index(indexes, pushables) do
    indexes
    |> Enum.map(fn idx ->
      {pushed, rest} = match_index(idx[:fields], pushables)
      {idx, pushed, rest}
    end)
    |> Enum.filter(fn {_idx, pushed, _rest} -> pushed != [] end)
    |> Enum.max_by(
      fn {_idx, pushed, _rest} ->
        {length(pushed), Enum.count(pushed, &Predicate.equality?/1)}
      end,
      fn -> {nil, [], pushables} end
    )
  end

  defp match_index(idx_fields, pushables), do: match_index(idx_fields, pushables, [])

  defp match_index([], pushables, acc), do: {Enum.reverse(acc), pushables}

  defp match_index([field | rest_fields], pushables, acc) do
    case take_pred(pushables, field, &Predicate.equality?/1) do
      {eq, rest} when eq != nil ->
        match_index(rest_fields, rest, [eq | acc])

      {nil, _} ->
        case take_pred(pushables, field, &Predicate.range?/1) do
          {range, rest} when range != nil -> {Enum.reverse([range | acc]), rest}
          {nil, _} -> {Enum.reverse(acc), pushables}
        end
    end
  end

  defp take_pred(preds, field, pred_fun),
    do: Predicate.take_first(preds, &(Predicate.field(&1) == field and pred_fun.(&1)))

  defp load_indexes(%Logical.Select{tenant: tenant, source: source}),
    do: indexes(tenant, source)

  @doc "A source's indexes, from the tenant's metadata, each with its `:id` and `:fields`."
  def indexes(tenant, source) do
    Metadata.transactional(tenant, source, fn _tx, metadata -> metadata.indexes end)
  end

  # -- classification --

  # Grouped by how they can be served (see Predicate.pushdown/1), each
  # group in its original order.
  defp classify(preds) do
    groups = Enum.group_by(preds, &Predicate.pushdown/1)
    {groups[:key] || [], groups[:in] || [], groups[:index] || [], groups[:filter] || []}
  end

  # -- IN planning --

  defp plan_in(
         logical,
         options,
         [{:in, in_field, values} = in_pred | extra_ins],
         rest,
         indexes,
         star?
       ) do
    residual = extra_ins ++ rest

    fanout_ok? =
      in_field == @pk_field or
        Enum.any?(indexes, fn idx -> List.first(idx[:fields]) == in_field end)

    if fanout_ok? do
      assemble(logical, options, &union_access(in_field, values, star?, &1, &2), residual, false)
    else
      full_scan(logical, options, [in_pred | residual])
    end
  end

  defp union_access(field, values, star?, query, options) do
    nodes =
      Enum.map(values, fn value ->
        if field == @pk_field do
          pk_access({:cmp, :==, @pk_field, value}, query, options)
        else
          scan_node(star?, put_wheres(query, [{:cmp, :==, field, value}]), options)
        end
      end)

    {:union, nodes}
  end

  # -- plan assembly --

  defp full_scan(logical, options, residual) do
    assemble(logical, options, fn q, opts -> {:pk_range, q, nil, nil, opts} end, residual, true)
  end

  defp assemble(logical, options, access_builder, residual, push_limit_ok?) do
    %Logical.Select{order: sort, limit: limit} = logical

    Enum.each(residual, &ensure_residual_evaluable!/1)
    Enum.each(sort, &ensure_sort_evaluable!/1)

    push_limit? = push_limit_ok? and residual == [] and sort == []
    {take, project} = takes(logical.projection, residual, sort)

    query =
      base_query(logical)
      |> put_select(take)
      |> put_limit(if(push_limit?, do: limit))

    ops =
      []
      |> append_if(residual != [], {:filter, residual})
      |> append_if(sort != [], {:sort, sort})
      |> append_if(not push_limit? and limit != nil, {:limit, limit})
      |> append_if(project != nil, {:project, project})

    %Plan{access: access_builder.(query, options), ops: ops}
  end

  defp append_if(list, true, item), do: list ++ [item]
  defp append_if(list, false, _item), do: list

  # -- primary key access --

  defp pk_access({:cmp, :==, _f, {part, :*}}, q, options) do
    id_a = {part, EctoFoundationDB.Versionstamp.min()}
    id_b = {part, EctoFoundationDB.Versionstamp.max()}

    {:pk_range, q, id_a, id_b,
     Keyword.merge(options, inclusive_left?: true, inclusive_right?: true)}
  end

  defp pk_access({:cmp, :==, _f, id}, q, options) do
    {:pk_range, q, id, id, Keyword.merge(options, inclusive_left?: true, inclusive_right?: true)}
  end

  defp pk_access({:range, _f, {lower_op, id_a}, {upper_op, id_b}}, q, options) do
    options1 = []
    options1 = if lower_op == :>, do: options1 ++ [inclusive_left?: false], else: options1
    options1 = if upper_op == :<=, do: options1 ++ [inclusive_right?: true], else: options1
    {:pk_range, q, id_a, id_b, Keyword.merge(options, options1)}
  end

  defp pk_access({:cmp, op, _f, id}, q, options) when op in ~w[> >= < <=]a do
    options1 = []
    options1 = if op == :>, do: options1 ++ [inclusive_left?: false], else: options1
    options1 = if op == :<=, do: options1 ++ [inclusive_right?: true], else: options1

    id_s = if op in ~w[> >=]a, do: id
    id_e = if op in ~w[< <=]a, do: id

    {:pk_range, q, id_s, id_e, Keyword.merge(options, options1)}
  end

  # -- select / projection --

  # Residual filtering and sorting read fields off the pulled rows, so those
  # fields must be part of the pushed select even when the user didn't ask
  # for them; a project operator trims the rows back down.
  defp takes(:star, _residual, _sort), do: {nil, nil}

  defp takes(fields, residual, sort) do
    needed =
      (Enum.flat_map(residual, &Predicate.fields/1) ++ Enum.map(sort, fn {_dir, f} -> f end))
      |> Enum.uniq()

    case needed -- fields do
      [] -> {fields, nil}
      extra -> {fields ++ extra, fields}
    end
  end

  defp ensure_residual_evaluable!(pred) do
    if @pk_field in Predicate.fields(pred) do
      # Rows carry the key under its field's name, not `_`, so a condition
      # on `_` must be one the key range can serve.
      raise Unsupported,
            "on the primary key '_', only =, <, <=, >, >=, BETWEEN and IN are supported " <>
              "(and an OR of = and IN); use the primary key field name for anything else"
    end
  end

  defp ensure_sort_evaluable!({_dir, @pk_field}) do
    raise Unsupported,
          "order by '_' is not supported; order by the primary key field name instead"
  end

  defp ensure_sort_evaluable!(_), do: :ok

  # -- Ecto query construction (the pushdown boundary) --

  defp base_query(%Logical.Select{source: source, tenant: tenant}) do
    %Ecto.Query{
      from: %Ecto.Query.FromExpr{source: {source, nil}, params: [], hints: []},
      prefix: tenant
    }
  end

  defp put_select(%Ecto.Query{} = q, nil), do: q

  defp put_select(%Ecto.Query{} = q, fields) do
    %Ecto.Query{
      q
      | select: %Ecto.Query.SelectExpr{
          expr: {:&, [], [0]},
          params: [],
          take: %{0 => {:any, fields}},
          subqueries: [],
          aliases: %{}
        }
    }
  end

  defp put_wheres(%Ecto.Query{} = q, preds) do
    wheres =
      Enum.map(preds, fn pred ->
        %Ecto.Query.BooleanExpr{
          op: :and,
          expr: Predicate.to_ecto(pred),
          params: [],
          subqueries: []
        }
      end)

    %Ecto.Query{q | wheres: wheres}
  end

  defp put_order(%Ecto.Query{} = q, []), do: q

  defp put_order(%Ecto.Query{} = q, order) do
    expr = Enum.map(order, fn {dir, field} -> {dir, Predicate.field_ref(field)} end)
    %Ecto.Query{q | order_bys: [%Ecto.Query.ByExpr{expr: expr, params: [], subqueries: []}]}
  end

  defp put_limit(%Ecto.Query{} = q, nil), do: q

  defp put_limit(%Ecto.Query{} = q, n) do
    %Ecto.Query{q | limit: %Ecto.Query.LimitExpr{expr: n, with_ties: false, params: []}}
  end
end
