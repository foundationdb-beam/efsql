defmodule Efsql.Cli do
  defstruct args: [], history: [], debug: false, session: %Efsql.Session{}

  use GenServer

  def run do
    cluster_file =
      Application.get_env(:efsql, Efsql.Repo, [])
      |> Keyword.get(:cluster_file, "default")

    IO.puts("Connected to #{cluster_file}")
    args = if System.get_env("EFSQL_DEBUG") == "true", do: [debug: true], else: []
    args = if System.get_env("EFSQL_NO_TUI") == "true", do: [{:tui, false} | args], else: args
    start_ui(args)
    System.halt(0)
  end

  def main(args) do
    {args, _, _} =
      OptionParser.parse(args,
        aliases: [C: :cluster_file],
        strict: [cluster_file: :string, storage_id: :string, debug: :boolean, tui: :boolean]
      )

    init_ecto_foundationdb!(args)
    start_ui(args)
  end

  # The full-screen TUI is the default on a tty; a pipe, --no-tui, or a
  # node that already runs a shell (iex) gets the line REPL.
  defp start_ui(args) do
    if Keyword.get(args, :tui, true) and Efsql.Tui.Term.tty?() do
      case Efsql.Tui.run(args) do
        :ok ->
          :ok

        {:error, reason} ->
          IO.puts("TUI unavailable (#{inspect(reason)}); using line mode")
          line_repl(args)
      end
    else
      line_repl(args)
    end
  end

  defp line_repl(args) do
    {:ok, pid} = GenServer.start_link(__MODULE__, args)
    mref = Process.monitor(pid)
    wait_for_down(pid, mref)
  end

  defp wait_for_down(pid, mref) do
    receive do
      {:DOWN, ^mref, :process, ^pid, :normal} ->
        :ok

      {:DOWN, ^mref, :process, ^pid, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(args) do
    IO.puts("[Ctrl+D to exit]")
    GenServer.cast(self(), :prompt_for_input)
    {:ok, %__MODULE__{args: args, debug: Keyword.get(args, :debug, false)}}
  end

  @impl true
  def handle_cast(:prompt_for_input, state = %__MODULE__{}) do
    IO.write("> ")

    case IO.read(:stdio, :line) do
      :eof ->
        {:stop, :normal, state}

      {:error, reason} ->
        raise reason

      data ->
        state = handle_input(String.trim(data), state)
        GenServer.cast(self(), :prompt_for_input)
        {:noreply, state}
    end
  end

  defp handle_input("", state = %__MODULE__{}), do: state

  defp handle_input("\\?", state = %__MODULE__{}) do
    Owl.IO.puts(
      Owl.Data.tag(
        """
        Meta-commands:
          \\tenants [storage_id]  list tenants (optionally for a specific storage id)
        #{settings_help(state.session.settings)}
          \\?                     show this help
        """,
        :light_black
      )
    )

    state
  end

  defp handle_input("\\tenants" <> rest, state = %__MODULE__{}) do
    storage_id =
      case String.trim(rest) do
        "" -> nil
        id -> id
      end

    try do
      config = Efsql.Repo.config()
      config = if storage_id, do: Keyword.put(config, :storage_id, storage_id), else: config
      db = Ecto.Adapters.FoundationDB.db(Efsql.Repo)
      tenant_ids = EctoFoundationDB.Tenant.Backend.list(db, config)

      case tenant_ids do
        [] ->
          Owl.IO.puts(Owl.Data.tag("(0 tenants)", :light_black))

        _ ->
          tenant_ids
          |> Enum.map(&%{"tenant" => &1})
          |> Owl.Table.new(border_style: :solid_rounded, padding_x: 1)
          |> Owl.IO.puts()

          n = length(tenant_ids)

          Owl.IO.puts(
            Owl.Data.tag("(#{n} #{if n == 1, do: "tenant", else: "tenants"})", :light_black)
          )
      end
    rescue
      e -> print_error(e)
    end

    state
  end

  defp handle_input("\\set " <> rest, state = %__MODULE__{}) do
    case Efsql.Settings.set(state.session.settings, rest) do
      {:ok, settings, message} ->
        Owl.IO.puts(Owl.Data.tag(message, :light_black))
        %__MODULE__{state | session: %{state.session | settings: settings}}

      {:error, usage} ->
        print_error(usage)
        state
    end
  end

  defp handle_input(data, state = %__MODULE__{}) do
    limit = state.session.settings.limit
    limit_sql = "limit #{limit + 1}"

    session =
      try do
        {sql, display_limit} =
          if String.match?(data, ~r/\blimit\b/i),
            do: {data, :all},
            else: {String.replace(data, ~r/;\s*$/, " #{limit_sql};"), limit}

        {result, session} = Efsql.Session.run(state.session, sql)
        if state.debug, do: print_debug(result.plan)
        print_table(result.rows, display_limit, result.columns)
        print_transactions(result.transactions)
        session
      rescue
        e ->
          print_error(e)
          state.session
      end

    %__MODULE__{state | history: [data | state.history], session: session}
  end

  def init_ecto_foundationdb!(args) do
    if Efsql.DevSandbox.enabled?() do
      # the application boots (or already booted) its own sandbox database
      {:ok, _} = Application.ensure_all_started(:efsql)
      IO.puts("Connected to dev sandbox")
    else
      cluster_file = get_cluster_file(args)
      storage_id = get_storage_id(args)

      opts =
        [cluster_file: cluster_file, storage_id: storage_id]
        |> Enum.filter(fn
          {_, nil} -> false
          _ -> true
        end)

      Application.put_env(:efsql, Efsql.Repo, opts)

      {:ok, _} = Application.ensure_all_started(:efsql)

      IO.puts("Connected to #{cluster_file}")
    end
  end

  defp get_cluster_file(args) do
    args[:cluster_file] || get_default_cluster_file()
  end

  defp get_storage_id(args) do
    args[:storage_id] || nil
  end

  defp get_default_cluster_file() do
    system_default = "/usr/local/etc/foundationdb/fdb.cluster"
    local_default = "./fdb.cluster"
    env_default = System.get_env("FDB_CLUSTER_FILE")

    if env_default do
      env_default
    else
      if File.exists?(local_default) do
        local_default
      else
        system_default
      end
    end
  end

  defp print_table([], _limit, _columns) do
    Owl.IO.puts(Owl.Data.tag("(0 rows)", :light_black))
  end

  defp print_table(rows, :all, columns) do
    print_rows(rows, false, columns)
  end

  defp print_table(rows, limit, columns) do
    {display_rows, more?} =
      if length(rows) > limit,
        do: {Enum.take(rows, limit), true},
        else: {rows, false}

    print_rows(display_rows, more?, columns)
  end

  defp print_rows(rows, more?, columns) do
    rows
    |> Enum.map(fn row ->
      Map.new(columns, &{to_string(&1), format_value(Map.get(row, &1))})
    end)
    |> Owl.Table.new(
      border_style: :solid_rounded,
      padding_x: 1,
      sort_columns: column_sorter(columns)
    )
    |> Owl.IO.puts()

    n = length(rows)
    label = if more?, do: "(#{n} rows, more available — add LIMIT)", else: "(#{n} rows)"
    Owl.IO.puts(Owl.Data.tag(label, :light_black))
  end

  defp settings_help(settings) do
    Enum.map_join(Efsql.Settings.describe(settings), "\n", fn {command, what} ->
      "  " <> String.pad_trailing(command, 22) <> " " <> what
    end)
  end

  defp print_transactions(1), do: :ok

  defp print_transactions(n) do
    Owl.IO.puts(Owl.Data.tag("(read in #{n} transactions)", :yellow))
  end

  # Owl sorts a table's columns; keep them in the result's order.
  defp column_sorter(columns) do
    position = columns |> Enum.map(&to_string/1) |> Enum.with_index() |> Map.new()
    &(Map.fetch!(position, &1) <= Map.fetch!(position, &2))
  end

  defp format_value(nil), do: Owl.Data.tag("null", :light_black)
  defp format_value(v) when is_binary(v), do: v

  defp format_value({:versionstamp, _, _, _} = v),
    do: to_string(EctoFoundationDB.Versionstamp.to_integer(v))

  defp format_value(v), do: inspect(v)

  defp print_debug(plan = %Efsql.Physical.Plan{}) do
    msg = "#{access_msg(plan.access)}\nefsql ops: #{inspect(plan.ops)}"
    Owl.IO.puts(Owl.Data.tag(msg, :light_black))
  end

  defp access_msg({:pk_range, query, id_a, id_b, options}) do
    "Repo.all_range(\n  #{inspect(query, pretty: true)},\n  #{inspect(id_a)},\n  #{inspect(id_b)},\n  #{inspect(options)}\n)"
  end

  defp access_msg({:index_scan, query, options}) do
    "Repo.all(\n  #{inspect(query, pretty: true)},\n  #{inspect(options)}\n)"
  end

  defp access_msg({:all_from_source, query, options}) do
    "Repo.all_from_source(\n  #{inspect(query, pretty: true)},\n  #{inspect(options)}\n)"
  end

  defp access_msg({:union, nodes}) do
    nodes
    |> Enum.map(&access_msg/1)
    |> Enum.join("\n")
    |> then(&"async union (#{length(nodes)}):\n#{&1}")
  end

  defp print_error(%{__exception__: true} = e),
    do: Owl.IO.puts(Owl.Data.tag(Exception.message(e), :red))

  defp print_error(term) when is_binary(term), do: Owl.IO.puts(Owl.Data.tag(term, :red))
  defp print_error(term), do: Owl.IO.puts(Owl.Data.tag(inspect(term), :red))
end
