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
  alias Efsql.Render
  alias Efsql.Tui.Help

  # Widest a results column can grow. Sized so a canonical UUID (36 chars)
  # fits without an ellipsis, since primary keys are the column you most
  # often need to read in full and then copy into another query.
  @max_col_width 36

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
              # entries matching the filter, recomputed only when either
              # changes (see `refilter/1`), so a held arrow key stays O(1)
              nav_visible: [],
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
              # rows rendered once per query result (see `done/3`): a list of
              # cell strings per row, and each column's natural width
              cells: [],
              col_widths: [],
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
              ifield_cursor: 0,
              ivalue_scroll: 0,
              ifocus: :fields,
              # {{field_cursor, cols}, wrapped lines} — see `inspector_value/1`
              ivalue: nil,
              # help
              help_scroll: 0,
              help_return: :schema
  end

  def init(opts) do
    model = %Model{
      cluster_file: Keyword.get(opts, :cluster_file, "default"),
      size: Keyword.get(opts, :size, {24, 80})
    }

    {model, [load_nav(model)]}
  end

  # -- global --

  def update(model, {:resize, size}), do: {%{model | size: size}, []} |> refresh_ivalue()

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

  # `?` is a plain character in the query editor, so there it is reached with
  # the \? command instead.
  def update(%Model{mode: mode} = model, {:char, "?"}) when mode != :query and mode != :help do
    {%{model | mode: :help, help_return: mode, help_scroll: 0}, []}
  end

  def update(%Model{mode: :help} = model, msg), do: help(clear_flash(model), msg)
  def update(%Model{mode: :navigator} = model, msg), do: navigator(clear_flash(model), msg)
  def update(%Model{mode: :schema} = model, msg), do: schema(clear_flash(model), msg)
  def update(%Model{mode: :query} = model, msg), do: query(clear_flash(model), msg) |> refresh_ivalue()
  def update(%Model{mode: :inspector} = model, msg), do: inspector(clear_flash(model), msg) |> refresh_ivalue()

  defp clear_flash(model), do: %{model | flash: nil}

  # -- help --

  defp help(model, {:key, key}) when key in [:esc, :enter], do: {%{model | mode: model.help_return}, []}
  defp help(model, {:char, c}) when c in ["q", "?"], do: {%{model | mode: model.help_return}, []}
  defp help(model, {:char, "g"}), do: {%{model | help_scroll: 0}, []}
  defp help(model, {:char, "G"}), do: {%{model | help_scroll: max_help_scroll(model)}, []}

  defp help(model, msg) do
    page = max(help_height(model) - 1, 1)

    delta =
      case msg do
        {:key, :up} -> -1
        {:char, "k"} -> -1
        {:key, :down} -> 1
        {:char, "j"} -> 1
        {:key, :page_up} -> -page
        {:key, :page_down} -> page
        {:char, " "} -> page
        {:char, "b"} -> -page
        _ -> 0
      end

    scroll = (model.help_scroll + delta) |> max(0) |> min(max_help_scroll(model))
    {%{model | help_scroll: scroll}, []}
  end

  defp help_height(%Model{size: {rows, _cols}}), do: max(rows - 2, 1)
  defp max_help_scroll(model), do: max(length(Help.lines()) - help_height(model), 0)

  # -- navigator --

  defp navigator(model, {:key, :up}), do: {move_nav(model, -1), []}
  defp navigator(model, {:key, :down}), do: {move_nav(model, 1), []}

  defp navigator(model, {:char, c}) do
    {refilter(%{model | nav_filter: model.nav_filter <> c, nav_cursor: 0}), []}
  end

  defp navigator(%Model{nav_filter: f} = model, {:key, :backspace}) when f != "" do
    {refilter(%{model | nav_filter: String.slice(f, 0..-2//1), nav_cursor: 0}), []}
  end

  defp navigator(%Model{nav_path: [_ | _]} = model, {:key, key}) when key in [:backspace, :esc] do
    model = refilter(%{model | nav_path: [], nav_filter: "", nav_cursor: 0, nav_entries: nil})
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
            model =
              refilter(%{
                model
                | nav_path: [name],
                  nav_filter: "",
                  nav_cursor: 0,
                  nav_entries: nil
              })

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

  def nav_visible(%Model{nav_visible: visible}), do: visible

  defp refilter(%Model{nav_entries: nil} = model), do: %{model | nav_visible: []}

  defp refilter(%Model{nav_entries: entries, nav_filter: filter} = model) do
    needle = String.downcase(filter)
    %{model | nav_visible: Enum.filter(entries, &String.contains?(String.downcase(&1), needle))}
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

      # migrate: false — see Efsql.resolve_tenant/2; the TUI never writes.
      tenant =
        EctoFoundationDB.Tenant.open(Efsql.Repo, tenant_id,
          storage_id: storage_id,
          migrate: false
        )
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
      "\\?" -> {%{model | mode: :help, help_return: :query, help_scroll: 0, input: "", qcursor: 0}, []}
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
      row ->
        model = %{model | mode: :inspector, irow: row, ifield_cursor: 0, ivalue_scroll: 0, ifocus: :fields, ivalue: nil}
        {model, []}
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

  # Tab moves focus between the field list and the value; arrows then act on
  # whichever has it. Paging keys always target the value, since it is the only
  # thing that scrolls.
  defp inspector(model, {:key, :tab}) do
    {%{model | ifocus: if(model.ifocus == :fields, do: :value, else: :fields)}, []}
  end

  defp inspector(model, {:key, key}) when key in [:page_down, :page_up] do
    {scroll_value(model, if(key == :page_down, do: page(model), else: -page(model))), []}
  end

  defp inspector(model, {:char, " "}), do: {scroll_value(model, page(model)), []}
  defp inspector(model, {:char, "b"}), do: {scroll_value(model, -page(model)), []}

  defp inspector(%Model{ifocus: :value} = model, {:char, "g"}), do: {%{model | ivalue_scroll: 0}, []}

  defp inspector(%Model{ifocus: :value} = model, {:char, "G"}) do
    {%{model | ivalue_scroll: max_value_scroll(model)}, []}
  end

  defp inspector(%Model{ifocus: :fields} = model, {:char, "g"}), do: {move_field(model, -model.ifield_cursor), []}

  defp inspector(%Model{ifocus: :fields} = model, {:char, "G"}) do
    {move_field(model, map_size(model.irow || %{})), []}
  end

  defp inspector(%Model{ifocus: :value} = model, msg) do
    {scroll_value(model, line_delta(msg)), []}
  end

  defp inspector(model, msg), do: {move_field(model, line_delta(msg)), []}

  defp line_delta({:key, :up}), do: -1
  defp line_delta({:char, "k"}), do: -1
  defp line_delta({:key, :down}), do: 1
  defp line_delta({:char, "j"}), do: 1
  defp line_delta(_), do: 0

  defp move_field(model, delta) do
    count = map_size(model.irow || %{})
    cursor = clamp(model.ifield_cursor + delta, count)

    # a different field starts at the top of its own value
    scroll = if cursor == model.ifield_cursor, do: model.ivalue_scroll, else: 0
    %{model | ifield_cursor: cursor, ivalue_scroll: scroll}
  end

  defp scroll_value(model, delta) do
    scroll = model.ivalue_scroll + delta
    %{model | ivalue_scroll: scroll |> max(0) |> min(max_value_scroll(model))}
  end

  # One page, keeping a line of context like a pager does.
  defp page(model) do
    {_lines, height} = inspector_value(model)
    max(height - 1, 1)
  end

  defp max_value_scroll(model) do
    {lines, height} = inspector_value(model)
    max(length(lines) - height, 0)
  end

  @doc """
  The wrapped lines of the selected value and how many of them fit on screen.
  Lives here so the scroll clamping and the view agree on one layout.

  Rendering and wrapping a large value is the expensive part, so `update/2`
  caches the lines in `ivalue` (keyed by field and width) and every key
  press in the inspector reuses them.
  """
  def inspector_value(%Model{irow: nil}), do: {[], 1}

  def inspector_value(%Model{irow: row, size: {rows, _cols}} = model) do
    key = ivalue_key(model)

    lines =
      case model.ivalue do
        {^key, lines} -> lines
        _ -> ivalue_lines(model)
      end

    height = max(rows - 2, 1)
    list_height = min(map_size(row), div(height, 2))
    # " Row" + the field list + a blank + the field-name header
    {lines, max(height - list_height - 3, 1)}
  end

  defp ivalue_key(%Model{ifield_cursor: ix, size: {_rows, cols}}), do: {ix, cols}

  defp ivalue_lines(%Model{irow: row, size: {_rows, cols}} = model) do
    fields = row |> Map.keys() |> Enum.sort()
    selected = Enum.at(fields, model.ifield_cursor)

    row
    |> Map.get(selected)
    |> Render.full(cols - 4)
    |> Render.wrap(cols - 4)
  end

  defp refresh_ivalue({%Model{mode: :inspector, irow: row} = model, cmds}) when row != nil do
    key = ivalue_key(model)

    case model.ivalue do
      {^key, _} -> {model, cmds}
      _ -> {%{model | ivalue: {key, ivalue_lines(model)}}, cmds}
    end
  end

  defp refresh_ivalue(result), do: result

  # -- task results --

  defp done(model, _tag, {:error, err}) do
    {%{model | busy: nil, flash: {:error, error_text(err)}}, []}
  end

  defp done(model, :nav_entries, {:ok, entries}) do
    {refilter(%{model | busy: nil, nav_entries: Enum.sort(entries)}), []}
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
    columns = columns(rows)
    cells = render_cells(rows, columns)

    model = %{
      model
      | busy: nil,
        rows: rows,
        columns: columns,
        cells: cells,
        col_widths: col_widths(columns, cells),
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

  # Cells are rendered once here rather than per frame: a frame is painted on
  # every key press, and inspecting every visible value each time is what
  # made the editor lag on wide or large rows.
  defp render_cells(rows, columns) do
    Enum.map(rows, fn row ->
      Enum.map(columns, &Render.cell(Map.get(row, &1), @max_col_width))
    end)
  end

  defp col_widths(columns, cells) do
    header = Enum.map(columns, &(&1 |> to_string() |> String.length()))

    cells
    |> Enum.reduce(header, fn row, widths ->
      Enum.zip_with(row, widths, &max(String.length(&1), &2))
    end)
    |> Enum.map(&min(&1, @max_col_width))
  end

  defp error_text(%{__exception__: true} = e), do: Exception.message(e)
  defp error_text(err), do: inspect(err)

  defp clamp(_ix, 0), do: 0
  defp clamp(ix, count), do: ix |> max(0) |> min(count - 1)
end
