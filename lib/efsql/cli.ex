defmodule Efsql.Cli do
  alias IO.ANSI.Table
  alias Efsql.QueryHelper

  defstruct args: [], history: []

  use GenServer

  def main(args) do
    {args, _, _} =
      OptionParser.parse(args,
        aliases: [C: :cluster_file],
        strict: [cluster_file: :string, storage_id: :string]
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
    {:ok, %__MODULE__{args: args}}
  end

  @impl true
  def handle_cast(:prompt_for_input, state) do
    IO.write("> ")

    case IO.read(:stdio, :line) do
      :eof ->
        {:stop, :normal, state}

      {:error, reason} ->
        raise reason

      data ->
        try do
          {query, stream} = Efsql.qall(data, limit: 2)
          print_table(query, stream)
        rescue
          e ->
            print_error(e)
        end

        %__MODULE__{history: history} = state

        GenServer.cast(self(), :prompt_for_input)
        {:noreply, %__MODULE__{state | history: [data | history]}}
    end
  end

  defp init_ecto_foundationdb!(args) do
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

  defp print_table(query, stream) do
    fields = QueryHelper.get_select_fields(query)
    Table.start(fields)

    stream
    |> Stream.map(&Map.to_list/1)
    |> Stream.chunk_every(10)
    |> Stream.each(&Table.format(&1, style: :light))
    |> Stream.run()

    Table.stop()
  end

  defp print_error(term) do
    IO.puts("#{IO.ANSI.red()}#{inspect(term)}#{IO.ANSI.reset()}")
  end
end
