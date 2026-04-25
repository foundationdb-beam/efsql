defmodule Efsql.Cli do
  defstruct args: [], history: [], debug: false, tenants: %{}, limit: 15

  use GenServer

  def run do
    cluster_file =
      Application.get_env(:efsql, Efsql.Repo, [])
      |> Keyword.get(:cluster_file, "default")

    IO.puts("Connected to #{cluster_file}")
    args = if System.get_env("EFSQL_DEBUG") == "true", do: [debug: true], else: []
    {:ok, pid} = GenServer.start_link(__MODULE__, args)
    mref = Process.monitor(pid)
    wait_for_down(pid, mref)
    System.halt(0)
  end

  def main(args) do
    {args, _, _} =
      OptionParser.parse(args,
        aliases: [C: :cluster_file],
        strict: [cluster_file: :string, storage_id: :string, debug: :boolean]
      )

    init_ecto_foundationdb!(args)

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
    Owl.IO.puts(Owl.Data.tag("""
    Meta-commands:
      \\tenants [storage_id]  list tenants (optionally for a specific storage id)
      \\set limit N           set the default row limit (currently #{state.limit})
      \\?                     show this help
    """, :light_black))
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
          Owl.IO.puts(Owl.Data.tag("(#{n} #{if n == 1, do: "tenant", else: "tenants"})", :light_black))
      end
    rescue
      e -> print_error(e)
    end

    state
  end

  defp handle_input("\\set limit " <> rest, state = %__MODULE__{}) do
    case Integer.parse(String.trim(rest)) do
      {n, ""} when n > 0 ->
        Owl.IO.puts(Owl.Data.tag("limit set to #{n}", :light_black))
        %__MODULE__{state | limit: n}

      _ ->
        print_error("Usage: \\set limit <positive integer>")
        state
    end
  end

  defp handle_input(data, state = %__MODULE__{}) do
    limit_sql = "limit #{state.limit + 1}"

    {tenants} =
      try do
        {sql, display_limit} =
          if String.match?(data, ~r/\blimit\b/i),
            do: {data, :all},
            else: {String.replace(data, ~r/;\s*$/, " #{limit_sql};"), state.limit}
        {call, rows, tenants} = Efsql.qall(sql, [], state.tenants)
        if state.debug, do: print_debug(call)
        print_table(rows, display_limit)
        {tenants}
      rescue
        e ->
          print_error(e)
          {state.tenants}
      end

    %__MODULE__{state | history: [data | state.history], tenants: tenants}
  end

  def init_ecto_foundationdb!(args) do
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

  defp print_table([], _limit) do
    Owl.IO.puts(Owl.Data.tag("(0 rows)", :light_black))
  end

  defp print_table(rows, :all) do
    print_rows(rows, false)
  end

  defp print_table(rows, limit) do
    {display_rows, more?} =
      if length(rows) > limit,
        do: {Enum.take(rows, limit), true},
        else: {rows, false}

    print_rows(display_rows, more?)
  end

  defp print_rows(rows, more?) do
    rows
    |> Enum.map(fn row ->
      Map.new(row, fn {k, v} -> {to_string(k), format_value(v)} end)
    end)
    |> Owl.Table.new(border_style: :solid_rounded, padding_x: 1)
    |> Owl.IO.puts()

    n = length(rows)
    label = if more?, do: "(#{n} rows, more available — add LIMIT)", else: "(#{n} rows)"
    Owl.IO.puts(Owl.Data.tag(label, :light_black))
  end

  defp format_value(nil), do: Owl.Data.tag("null", :light_black)
  defp format_value(v) when is_binary(v), do: v
  defp format_value({:versionstamp, _, _, _} = v), do: to_string(EctoFoundationDB.Versionstamp.to_integer(v))
  defp format_value(v), do: inspect(v)

  defp print_debug({:all_range, query, id_a, id_b, options}) do
    msg = "Repo.all_range(\n  #{inspect(query, pretty: true)},\n  #{inspect(id_a)},\n  #{inspect(id_b)},\n  #{inspect(options)}\n)"
    Owl.IO.puts(Owl.Data.tag(msg, :light_black))
  end

  defp print_debug({:all, query, options}) do
    msg = "Repo.all(\n  #{inspect(query, pretty: true)},\n  #{inspect(options)}\n)"
    Owl.IO.puts(Owl.Data.tag(msg, :light_black))
  end

  defp print_error(term) do
    Owl.IO.puts(Owl.Data.tag(inspect(term), :red))
  end
end
