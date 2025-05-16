defmodule Efsql.Cli do
  alias IO.ANSI.Table
  alias Efsql.QueryHelper

  def main(args) do
    {args, _, _} =
      OptionParser.parse(args,
        aliases: [C: :cluster_file],
        strict: [cluster_file: :string, storage_id: :string]
      )

    init_ecto_foundationdb!(args)

    loop(args)
  end

  def loop(args) do
    IO.write("> ")

    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, reason} ->
        raise reason

      data ->
        try do
          {query, stream} = Efsql.stream(data)
          print_table(query, stream)
        rescue
          e ->
            print_error(e)
        end

        loop(args)
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

    IO.puts("#{inspect(opts)}")

    Application.put_env(:efsql, Efsql.Repo, opts)

    {:ok, _} = Application.ensure_all_started(:efsql)
  end

  defp get_cluster_file(args) do
    IO.inspect(args, label: "args")
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
