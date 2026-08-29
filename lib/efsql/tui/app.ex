defmodule Efsql.Tui.App do
  @moduledoc """
  The TUI's pure core: a model, and `update(model, msg) -> {model, cmds}`.

  Messages: `{:key, name}`, `{:char, grapheme}`, `{:resize, {rows, cols}}`,
  `{:done, tag, {:ok, result} | {:error, err}}`.

  Commands are data interpreted by `Efsql.Tui` (the impure loop):
  `:quit`, `{:task, tag, fun}`. Every FDB touch goes through a task so the
  UI never blocks.
  """

  alias Efsql.Complete
  alias Efsql.Discover

  defmodule Model do
    defstruct size: {24, 80},
              mode: :navigator,
              flash: nil,
              busy: nil,
              limit: 15,
              cluster_file: nil,
              # navigator
              nav_path: [],
              nav_entries: nil,
              nav_cursor: 0,
              nav_filter: "",
              # session
              storage_id: nil,
              tenant_id: nil,
              tenant: nil,
              tenants: %{},
              # schema browser
              sources: nil,
              src_cursor: 0,
              schemas: %{},
              field_cursor: 0,
              focus: :sources,
              # query
              input: "",
              qcursor: 0,
              history: [],
              hist_ix: nil,
              saved_input: "",
              rows: nil,
              columns: [],
              plan: nil,
              qerror: nil,
              elapsed_ms: nil,
              row_cursor: 0,
              row_scroll: 0,
              qfocus: :input,
              show_plan?: false,
              completion: nil,
              # inspector
              irow: nil,
              ifield_cursor: 0
  end

  def init(opts) do
    model = %Model{
      cluster_file: Keyword.get(opts, :cluster_file, "default"),
      size: Keyword.get(opts, :size, {24, 80})
    }

    {model, [load_nav(model)]}
  end

  # -- global --

  def update(model, {:resize, size}), do: {%{model | size: size}, []}

  # Esc is the reliable cancel: Ctrl-C only reaches us as a byte when the
  # emulator's break handling is off, so both are accepted.
  def update(%Model{busy: busy} = model, {:key, key}) when busy != nil and key in [:esc, :ctrl_c] do
    {%{model | busy: nil, flash: {:info, "cancelled"}}, [:cancel_tasks]}
  end

  def update(model, {:key, :ctrl_c}), do: {model, [:quit]}
  def update(model, {:key, :ctrl_d}), do: {model, [:quit]}
  def update(model, {:key, :ctrl_l}), do: {model, []}

  def update(model, {:done, tag, result}), do: done(model, tag, result)

  # While a task runs, only the global keys above are live.
  def update(%Model{busy: busy} = model, _msg) when busy != nil, do: {model, []}

  def update(%Model{mode: :navigator} = model, msg), do: navigator(clear_flash(model), msg)
  def update(%Model{mode: :schema} = model, msg), do: schema(clear_flash(model), msg)
  def update(%Model{mode: :query} = model, msg), do: query(clear_flash(model), msg)
  def update(%Model{mode: :inspector} = model, msg), do: inspector(clear_flash(model), msg)

  defp clear_flash(model), do: %{model | flash: nil}

  # -- navigator --

  defp navigator(model, {:key, :up}), do: {move_nav(model, -1), []}
  defp navigator(model, {:key, :down}), do: {move_nav(model, 1), []}

  defp navigator(model, {:char, c}) do
    {%{model | nav_filter: model.nav_filter <> c, nav_cursor: 0}, []}
  end

  defp navigator(%Model{nav_filter: f} = model, {:key, :backspace}) when f != "" do
    {%{model | nav_filter: String.slice(f, 0..-2//1), nav_cursor: 0}, []}
  end

  defp navigator(%Model{nav_path: [_ | _]} = model, {:key, key}) when key in [:backspace, :esc] do
    model = %{model | nav_path: [], nav_filter: "", nav_cursor: 0, nav_entries: nil}
    {model, [load_nav(model)]}
  end

  defp navigator(%Model{tenant: tenant} = model, {:key, :esc}) when tenant != nil do
    {%{model | mode: :schema}, []}
  end

  defp navigator(model, {:key, :enter}) do
    case Enum.at(nav_visible(model), model.nav_cursor) do
      nil ->
        {model, []}

      name ->
        case model.nav_path do
          [] ->
            model = %{
              model
              | nav_path: [name],
                nav_filter: "",
                nav_cursor: 0,
                nav_entries: nil
            }

            {model, [load_nav(model)]}

          [storage_id] ->
            activate(model, storage_id, name)
        end
    end
  end

  defp navigator(model, _msg), do: {model, []}

  defp move_nav(model, delta) do
    count = length(nav_visible(model))
    %{model | nav_cursor: clamp(model.nav_cursor + delta, count)}
  end

  def nav_visible(%Model{nav_entries: nil}), do: []

  def nav_visible(%Model{nav_entries: entries, nav_filter: filter}) do
    Enum.filter(entries, &String.contains?(String.downcase(&1), String.downcase(filter)))
  end

  defp load_nav(%Model{nav_path: []}) do
    {:task, :nav_entries, fn -> Discover.storage_ids() end}
  end

  defp load_nav(%Model{nav_path: [storage_id]}) do
    {:task, :nav_entries, fn -> Discover.tenants(storage_id) end}
  end

  defp activate(model, storage_id, tenant_id) do
    fun = fn ->
      Discover.ensure_storage_cache(storage_id)
      db = Ecto.Adapters.FoundationDB.db(Efsql.Repo)
      config = Keyword.put(Efsql.Repo.config(), :storage_id, storage_id)

      unless EctoFoundationDB.Tenant.Backend.exists?(db, tenant_id, config) do
        raise "Tenant '#{tenant_id}' does not exist"
      end

      tenant = EctoFoundationDB.Tenant.open(Efsql.Repo, tenant_id, storage_id: storage_id)
      {storage_id, tenant_id, tenant}
    end

    {%{model | busy: "opening #{tenant_id}"}, [{:task, :activate, fun}]}
  end

  # -- schema browser --

  defp schema(model, {:key, key}) when key in [:up, :down] or key in [:page_up, :page_down] do
    delta =
      case key do
        :up -> -1
        :down -> 1
        :page_up -> -10
        :page_down -> 10
      end

    move_schema(model, delta)
  end

  defp schema(model, {:char, c}) when c in ["j", "k"] do
    move_schema(model, if(c == "j", do: 1, else: -1))
  end

  defp schema(%Model{focus: :fields} = model, {:key, key}) when key in [:left, :esc] do
    {%{model | focus: :sources}, []}
  end

  defp schema(%Model{focus: :sources} = model, {:key, :right}), do: enter_source(model)
  defp schema(%Model{focus: :sources} = model, {:char, "l"}), do: enter_source(model)
  defp schema(%Model{focus: :sources} = model, {:key, :enter}), do: enter_source(model)
  defp schema(%Model{focus: :fields} = model, {:char, "h"}), do: {%{model | focus: :sources}, []}

  defp schema(%Model{focus: :fields} = model, {:key, :enter}) do
    with source when source != nil <- current_source(model),
         %Discover.Schema{fields: fields} <- model.schemas[source],
         %{name: field} <- Enum.at(fields, model.field_cursor) do
      input = "select #{field} from #{source} limit #{model.limit};"
      {%{model | mode: :query, input: input, qcursor: String.length(input), qfocus: :input}, []}
    else
      _ -> {model, []}
    end
  end

  defp schema(model, {:char, "q"}), do: {%{model | mode: :query}, []}
  defp schema(model, {:char, "t"}), do: {%{model | mode: :navigator}, []}
  defp schema(%Model{tenant: t} = model, {:key, :esc}) when t != nil, do: {%{model | mode: :navigator}, []}

  defp schema(model, {:char, "r"}) do
    case current_source(model) do
      nil -> {model, []}
      source -> {%{model | busy: "sampling #{source}"}, [sample_task(model, source)]}
    end
  end

  defp schema(model, _msg), do: {model, []}

  defp enter_source(model) do
    case current_source(model) do
      nil ->
        {model, []}

      source ->
        model = %{model | focus: :fields, field_cursor: 0}

        cond do
          Map.has_key?(model.schemas, source) ->
            {model, []}

          true ->
            case Discover.cache_get(schema_cache_key(model, source)) do
              {:ok, schema} ->
                {put_schema(model, source, schema), []}

              :miss ->
                {%{model | busy: "sampling #{source}"}, [sample_task(model, source)]}
            end
        end
    end
  end

  defp move_schema(%Model{focus: :sources} = model, delta) do
    count = length(model.sources || [])
    {%{model | src_cursor: clamp(model.src_cursor + delta, count)}, []}
  end

  defp move_schema(%Model{focus: :fields} = model, delta) do
    count =
      case model.schemas[current_source(model)] do
        %Discover.Schema{fields: fields} -> length(fields)
        _ -> 0
      end

    {%{model | field_cursor: clamp(model.field_cursor + delta, count)}, []}
  end

  def current_source(%Model{sources: sources, src_cursor: ix}) when is_list(sources) do
    Enum.at(sources, ix)
  end

  def current_source(_), do: nil

  defp sample_task(model, source) do
    tenant = model.tenant
    key = schema_cache_key(model, source)

    {:task, {:schema, source},
     fn ->
       schema = Discover.schema(tenant, source)
       Discover.cache_put(key, schema)
       schema
     end}
  end

  defp schema_cache_key(model, source) do
    {model.cluster_file, model.storage_id, model.tenant_id, source}
  end

  defp put_schema(model, source, schema) do
    %{model | schemas: Map.put(model.schemas, source, schema)}
  end

  # -- query --

  defp query(%Model{qfocus: :results} = model, msg), do: results(model, msg)

  defp query(model, {:char, c}) do
    {pre, post} = String.split_at(model.input, model.qcursor)
    {%{model | input: pre <> c <> post, qcursor: model.qcursor + 1, completion: nil}, []}
  end

  defp query(%Model{qcursor: n} = model, {:key, :backspace}) when n > 0 do
    {pre, post} = String.split_at(model.input, n)
    {%{model | input: String.slice(pre, 0..-2//1) <> post, qcursor: n - 1, completion: nil}, []}
  end

  defp query(model, {:key, :delete}) do
    {pre, post} = String.split_at(model.input, model.qcursor)
    {%{model | input: pre <> String.slice(post, 1..-1//1), completion: nil}, []}
  end

  defp query(model, {:key, :left}), do: {%{model | qcursor: max(model.qcursor - 1, 0), completion: nil}, []}

  defp query(model, {:key, :right}) do
    {%{model | qcursor: min(model.qcursor + 1, String.length(model.input)), completion: nil}, []}
  end

  defp query(model, {:key, k}) when k in [:home, :ctrl_a], do: {%{model | qcursor: 0}, []}
  defp query(model, {:key, k}) when k in [:end, :ctrl_e], do: {%{model | qcursor: String.length(model.input)}, []}
  defp query(model, {:key, :ctrl_u}), do: {%{model | input: "", qcursor: 0, completion: nil}, []}

  defp query(model, {:key, :ctrl_k}) do
    {pre, _} = String.split_at(model.input, model.qcursor)
    {%{model | input: pre, completion: nil}, []}
  end

  defp query(model, {:key, :up}), do: {history(model, 1), []}
  defp query(model, {:key, :down}), do: {history(model, -1), []}

  defp query(%Model{input: "", rows: rows} = model, {:key, :tab}) when is_list(rows) do
    {%{model | qfocus: :results}, []}
  end

  defp query(model, {:key, :tab}), do: {complete(model), []}

  defp query(%Model{tenant: t} = model, {:key, :esc}) when t != nil, do: {%{model | mode: :schema}, []}
  defp query(model, {:key, :esc}), do: {%{model | mode: :navigator}, []}

  defp query(%Model{input: input} = model, {:key, :enter}) do
    case String.trim(input) do
      "" -> {model, []}
      "\\plan" -> {%{model | show_plan?: not model.show_plan?, input: "", qcursor: 0}, []}
      "\\set limit " <> n -> set_limit(model, n)
      sql -> run_query(model, sql)
    end
  end

  defp query(model, _msg), do: {model, []}

  defp set_limit(model, n) do
    case Integer.parse(String.trim(n)) do
      {n, ""} when n > 0 -> {%{model | limit: n, input: "", qcursor: 0, flash: {:info, "limit set to #{n}"}}, []}
      _ -> {%{model | flash: {:error, "usage: \\set limit N"}, input: "", qcursor: 0}, []}
    end
  end

  defp run_query(model, sql) do
    sql = if String.ends_with?(sql, ";"), do: sql, else: sql <> ";"
    session = %{tenant: model.tenant, tenants: model.tenants}

    fun = fn ->
      started = System.monotonic_time(:millisecond)
      {plan, rows, tenants} = Efsql.Tui.Session.qall(sql, session)
      {plan, rows, tenants, System.monotonic_time(:millisecond) - started}
    end

    model = %{
      model
      | busy: "running query",
        history: [sql | Enum.reject(model.history, &(&1 == sql))],
        hist_ix: nil,
        input: "",
        qcursor: 0,
        completion: nil
    }

    {model, [{:task, :query, fun}]}
  end

  defp history(%Model{history: []} = model, _), do: {model, []}

  defp history(model, dir) do
    max_ix = length(model.history) - 1

    case {model.hist_ix, dir} do
      {nil, 1} ->
        %{model | hist_ix: 0, saved_input: model.input} |> put_hist()

      {nil, -1} ->
        model

      {0, -1} ->
        %{model | hist_ix: nil, input: model.saved_input, qcursor: String.length(model.saved_input)}

      {ix, dir} ->
        %{model | hist_ix: clamp(ix + dir, max_ix + 1)} |> put_hist()
    end
  end

  defp put_hist(%Model{hist_ix: ix} = model) do
    input = Enum.at(model.history, ix)
    %{model | input: input, qcursor: String.length(input)}
  end

  defp complete(model) do
    {pre, post} = String.split_at(model.input, model.qcursor)

    case model.completion do
      {word_start, candidates, ix, tail} when candidates != [] ->
        ix = rem(ix + 1, length(candidates))
        apply_completion(model, word_start, candidates, ix, tail)

      _ ->
        context = completion_context(model)

        case Complete.complete(pre, context) do
          {_start, []} -> model
          {word_start, candidates} -> apply_completion(model, word_start, candidates, 0, post)
        end
    end
  end

  defp apply_completion(model, word_start, candidates, ix, tail) do
    candidate = Enum.at(candidates, ix)
    pre = String.slice(model.input, 0, word_start)

    %{
      model
      | input: pre <> candidate <> tail,
        qcursor: String.length(pre <> candidate),
        completion: {word_start, candidates, ix, tail}
    }
  end

  def completion_context(model) do
    fields =
      Map.new(model.schemas, fn {source, %Discover.Schema{fields: fields}} ->
        {source, Enum.map(fields, &to_string(&1.name))}
      end)

    %{tables: model.sources || [], fields: fields}
  end

  # -- query results focus --

  defp results(model, {:key, key}) when key in [:esc, :tab], do: {%{model | qfocus: :input}, []}

  defp results(model, {:key, key}) when key in [:up, :down, :page_up, :page_down] do
    delta =
      case key do
        :up -> -1
        :down -> 1
        :page_up -> -10
        :page_down -> 10
      end

    {move_row(model, delta), []}
  end

  defp results(model, {:char, c}) when c in ["j", "k"] do
    {move_row(model, if(c == "j", do: 1, else: -1)), []}
  end

  defp results(%Model{rows: rows} = model, {:key, :enter}) do
    case Enum.at(rows || [], model.row_cursor) do
      nil -> {model, []}
      row -> {%{model | mode: :inspector, irow: row, ifield_cursor: 0}, []}
    end
  end

  defp results(model, _msg), do: {model, []}

  defp move_row(model, delta) do
    count = length(model.rows || [])
    %{model | row_cursor: clamp(model.row_cursor + delta, count)}
  end

  # -- inspector --

  defp inspector(model, {:key, key}) when key in [:esc, :enter] do
    {%{model | mode: :query, irow: nil}, []}
  end

  defp inspector(model, msg) do
    delta =
      case msg do
        {:key, :up} -> -1
        {:char, "k"} -> -1
        {:key, :down} -> 1
        {:char, "j"} -> 1
        _ -> 0
      end

    count = map_size(model.irow || %{})
    {%{model | ifield_cursor: clamp(model.ifield_cursor + delta, count)}, []}
  end

  # -- task results --

  defp done(model, _tag, {:error, err}) do
    {%{model | busy: nil, flash: {:error, error_text(err)}}, []}
  end

  defp done(model, :nav_entries, {:ok, entries}) do
    {%{model | busy: nil, nav_entries: Enum.sort(entries)}, []}
  end

  defp done(model, :activate, {:ok, {storage_id, tenant_id, tenant}}) do
    model = %{
      model
      | busy: "listing sources",
        storage_id: storage_id,
        tenant_id: tenant_id,
        tenant: tenant,
        mode: :schema,
        sources: nil,
        src_cursor: 0,
        schemas: %{},
        focus: :sources,
        rows: nil,
        plan: nil,
        qerror: nil
    }

    {model, [{:task, :sources, fn -> Discover.sources(tenant) end}]}
  end

  defp done(model, :sources, {:ok, sources}) do
    {%{model | busy: nil, sources: sources, src_cursor: 0}, []}
  end

  defp done(model, {:schema, source}, {:ok, schema}) do
    {%{put_schema(model, source, schema) | busy: nil}, []}
  end

  defp done(model, :query, {:ok, {plan, rows, tenants, elapsed}}) do
    model = %{
      model
      | busy: nil,
        rows: rows,
        columns: columns(rows),
        plan: plan,
        qerror: nil,
        elapsed_ms: elapsed,
        row_cursor: 0,
        row_scroll: 0,
        tenants: tenants
    }

    {model, []}
  end

  defp done(model, _tag, _result), do: {%{model | busy: nil}, []}

  defp columns([]), do: []

  defp columns(rows) do
    keys = rows |> Enum.flat_map(&Map.keys/1) |> Enum.uniq() |> Enum.sort()
    if :id in keys, do: [:id | List.delete(keys, :id)], else: keys
  end

  defp error_text(%{__exception__: true} = e), do: Exception.message(e)
  defp error_text(err), do: inspect(err)

  defp clamp(_ix, 0), do: 0
  defp clamp(ix, count), do: ix |> max(0) |> min(count - 1)
end
