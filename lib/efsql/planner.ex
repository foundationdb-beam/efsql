defmodule Efsql.Planner do
  @moduledoc """
  Access-path selection: turns a normalized `Efsql.Logical.Select` into an
  `Efsql.Physical.Plan`.

  The planner reads the tenant's index metadata to decide the split
  deterministically: the predicates pushed to the adapter are exactly an
  equality-prefix of one index (optionally ending in a single range), and
  everything else becomes a `{:filter, ...}` operator.

  Ordering is pushed to the adapter when it can serve it natively — a single
  sort field that is the first index field after the pushed equalities (the
  adapter then scans the index in sort order, honoring the limit without
  pulling the full result set). Otherwise a `{:sort, ...}` operator sorts
  after the pull. The adapter's native ordering for schemaless primary-key
  scans is not usable (it requires a schema), so `order by <pk>` is always
  sorted client-side.

  `select *` cannot be expressed through `Repo.all` for schemaless sources,
  so it is only supported where `Repo.all_range` serves the query: primary
  key constraints (including `_ in` fan-out) and whole-table queries with no
  where clause. Field constraints with `select *` are rejected rather than
  silently falling back to a full-table scan.
  """

  alias Efsql.Exception.Unsupported
  alias Efsql.Logical
  alias Efsql.Physical.Plan
  alias EctoFoundationDB.Layer.Metadata

  @pk_field :_

  def plan(%Logical.Select{} = logical, options) do
    %Logical.Select{predicates: preds, order: sort, projection: projection} = logical
    star? = projection == :star
    {pks, ins, pushables, residuals} = classify(preds)

    indexes =
      if pks == [] and (ins != [] or pushables != [] or sort != []) do
        load_indexes(logical)
      else
        []
      end

    if star? and pks == [] and
         (pushables != [] or residuals != [] or
            Enum.any?(ins, fn {:in, field, _} -> field != @pk_field end)) do
      raise Unsupported,
            "SELECT * is not supported for index queries; select explicit fields instead"
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

  @doc """
  A plain Ecto query with every predicate as a where clause, for callers
  that hand the query to the adapter unplanned (e.g. `Repo.stream`).
  """
  def to_ecto_query(%Logical.Select{} = logical) do
    take = if logical.projection == :star, do: nil, else: logical.projection

    base_query(logical)
    |> put_select(take)
    |> put_wheres(logical.predicates)
    |> put_order(logical.order)
    |> put_limit(logical.limit)
  end

  # -- SELECT planning --

  defp plan_select(logical, options, pushables, residuals, indexes, star?) do
    {idx, pushed, rest} =
      if star?, do: {nil, [], pushables}, else: choose_index(indexes, pushables)

    residual = rest ++ residuals

    cond do
      native_sort?(logical.order, residual, star?, idx, pushed, indexes) ->
        native_sorted_plan(logical, options, pushed)

      pushed != [] ->
        assemble(
          logical,
          options,
          fn q, opts -> {:index_scan, put_wheres(q, pushed), opts} end,
          residual,
          true
        )

      true ->
        full_scan(logical, options, residual)
    end
  end

  # Adapter-native ordering: single sort field, nothing filtered after the
  # pull (else the pushed limit would be wrong), a select the adapter can
  # execute, and a sort field the chosen index scan actually delivers in
  # order — the first index field not pinned by an equality.
  defp native_sort?([{_dir, field}], [] = _residual, false = _star?, idx, pushed, indexes) do
    if idx == nil do
      Enum.any?(indexes, fn ix -> List.first(ix[:fields]) == field end)
    else
      equal_fields = for {:cmp, :==, f, _v} <- pushed, do: f
      List.first(idx[:fields] -- equal_fields) == field
    end
  end

  defp native_sort?(_sort, _residual, _star?, _idx, _pushed, _indexes), do: false

  defp native_sorted_plan(logical, options, pushed) do
    query =
      base_query(logical)
      |> put_select(logical.projection)
      |> put_wheres(pushed)
      |> put_order(logical.order)
      |> put_limit(logical.limit)

    %Plan{access: {:index_scan, query, options}, ops: []}
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
        {length(pushed), Enum.count(pushed, &match?({:cmp, :==, _, _}, &1))}
      end,
      fn -> {nil, [], pushables} end
    )
  end

  defp match_index(idx_fields, pushables), do: match_index(idx_fields, pushables, [])

  defp match_index([], pushables, acc), do: {Enum.reverse(acc), pushables}

  defp match_index([field | rest_fields], pushables, acc) do
    case take_pred(pushables, field, &match?({:cmp, :==, _, _}, &1)) do
      {eq, rest} when eq != nil ->
        match_index(rest_fields, rest, [eq | acc])

      {nil, _} ->
        case take_pred(pushables, field, &range?/1) do
          {range, rest} when range != nil -> {Enum.reverse([range | acc]), rest}
          {nil, _} -> {Enum.reverse(acc), pushables}
        end
    end
  end

  defp take_pred(preds, field, pred_fun) do
    case Enum.split_while(preds, fn p ->
           not (Logical.predicate_field(p) == field and pred_fun.(p))
         end) do
      {_before, []} -> {nil, preds}
      {before, [match | rest]} -> {match, before ++ rest}
    end
  end

  defp range?({:range, _field, _lower, _upper}), do: true
  defp range?({:cmp, op, _field, _value}) when op in ~w[> >= < <=]a, do: true
  defp range?(_), do: false

  defp load_indexes(%Logical.Select{tenant: tenant, source: source}) do
    Metadata.transactional(tenant, source, fn _tx, metadata -> metadata.indexes end)
  end

  # -- classification --

  defp classify(preds) do
    Enum.reduce(preds, {[], [], [], []}, fn pred, {pks, ins, pushables, residuals} ->
      case kind(pred) do
        :pk -> {pks ++ [pred], ins, pushables, residuals}
        :in -> {pks, ins ++ [pred], pushables, residuals}
        :pushable -> {pks, ins, pushables ++ [pred], residuals}
        :residual -> {pks, ins, pushables, residuals ++ [pred]}
      end
    end)
  end

  defp kind({:in, _field, _values}), do: :in
  defp kind({:like, _field, _pattern}), do: :residual
  defp kind({:not_like, _field, _pattern}), do: :residual
  defp kind({:cmp, _op, @pk_field, _value}), do: :pk
  defp kind({:range, @pk_field, _lower, _upper}), do: :pk
  defp kind({:cmp, _op, _field, _value}), do: :pushable
  defp kind({:range, _field, _lower, _upper}), do: :pushable

  # -- IN planning --

  defp plan_in(logical, options, [{:in, in_field, values} = in_pred | extra_ins], rest, indexes, star?) do
    residual = extra_ins ++ rest

    fanout_ok? =
      in_field == @pk_field or
        (not star? and Enum.any?(indexes, fn idx -> List.first(idx[:fields]) == in_field end))

    if fanout_ok? do
      assemble(logical, options, &union_access(in_field, values, &1, &2), residual, false)
    else
      full_scan(logical, options, [in_pred | residual])
    end
  end

  defp union_access(field, values, query, options) do
    nodes =
      Enum.map(values, fn value ->
        if field == @pk_field do
          pk_access({:cmp, :==, @pk_field, value}, query, options)
        else
          {:index_scan, put_wheres(query, [{:cmp, :==, field, value}]), options}
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
    {:pk_range, q, id_a, id_b, Keyword.merge(options, inclusive_left?: true, inclusive_right?: true)}
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
      (Enum.map(residual, &Logical.predicate_field/1) ++ Enum.map(sort, fn {_dir, f} -> f end))
      |> Enum.uniq()

    case needed -- fields do
      [] -> {fields, nil}
      extra -> {fields ++ extra, fields}
    end
  end

  defp ensure_residual_evaluable!(pred) do
    if Logical.predicate_field(pred) == @pk_field do
      raise Unsupported,
            "a constraint on the primary key '_' cannot be combined with this query shape"
    end
  end

  defp ensure_sort_evaluable!({_dir, @pk_field}) do
    raise Unsupported, "order by '_' is not supported; order by the primary key field name instead"
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
        %Ecto.Query.BooleanExpr{op: :and, expr: pred_to_expr(pred), params: [], subqueries: []}
      end)

    %Ecto.Query{q | wheres: wheres}
  end

  defp put_order(%Ecto.Query{} = q, []), do: q

  defp put_order(%Ecto.Query{} = q, order) do
    expr = Enum.map(order, fn {dir, field} -> {dir, field_ref(field)} end)
    %Ecto.Query{q | order_bys: [%Ecto.Query.ByExpr{expr: expr, params: [], subqueries: []}]}
  end

  defp put_limit(%Ecto.Query{} = q, nil), do: q

  defp put_limit(%Ecto.Query{} = q, n) do
    %Ecto.Query{q | limit: %Ecto.Query.LimitExpr{expr: n, with_ties: false, params: []}}
  end

  defp pred_to_expr({:cmp, op, field, value}) do
    {op, [], [field_ref(field), value]}
  end

  defp pred_to_expr({:range, field, {lower_op, lower}, {upper_op, upper}}) do
    {{lower_op, [], [field_ref(field), lower]}, {upper_op, [], [field_ref(field), upper]}}
  end

  defp pred_to_expr(pred) do
    raise Unsupported, "predicate #{inspect(pred)} cannot be pushed to the adapter"
  end

  defp field_ref(field) do
    {{:., [], [{:&, [], [0]}, field]}, [], []}
  end
end
