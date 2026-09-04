defmodule Efsql.Discover do
  @moduledoc """
  Data discovery for a schemaless database: navigate the FDB directory
  hierarchy (storage_ids -> tenants), enumerate the sources ("tables")
  inside a tenant, and infer a soft schema for a source by sampling rows.

  Everything here is read-only: directory listing, snapshot range reads,
  and the same query pipeline the SQL frontend uses. Discovered schemas
  are cached under `~/.efsql/cache/` (see `cache_put/2`, `cache_get/1`).
  """

  alias Efsql.Executor
  alias Efsql.Logical
  alias Efsql.Planner
  alias Efsql.Render

  @adapter_prefix <<0xFD>>
  @internal_sources ["schema_migrations", "indexes"]
  @cache_version 1

  defmodule Schema do
    defstruct source: nil,
              sampled: 0,
              sampled_at: nil,
              fields: [],
              pk: nil,
              indexes: []
  end

  # -- directory hierarchy --

  @doc "Lists directory names at the root of the FDB directory layer (candidate storage_ids)."
  def storage_ids(repo \\ Efsql.Repo) do
    db = Ecto.Adapters.FoundationDB.db(repo)

    for {{:utf8, name}, _node} <- :erlfdb_directory.list(db, root_node()) do
      name
    end
  end

  @doc "Lists tenant names under one storage_id directory."
  def tenants(storage_id, repo \\ Efsql.Repo) do
    ensure_storage_cache(storage_id)
    db = Ecto.Adapters.FoundationDB.db(repo)
    config = Keyword.put(repo.config(), :storage_id, storage_id)
    EctoFoundationDB.Tenant.Backend.list(db, config)
  rescue
    # a plain directory that is not an ecto_fdb storage layout
    _ -> []
  end

  @doc """
  The adapter keeps a directory-cache ETS table per storage_id, normally
  started only for the Repo's configured one. Browsing other storage_ids
  needs their caches started on demand (idempotent).
  """
  def ensure_storage_cache(storage_id) do
    spec =
      Supervisor.child_spec(
        {EctoFoundationDB.TenantCache, [[storage_id: storage_id]]},
        id: {:tenant_cache, storage_id},
        restart: :temporary
      )

    case DynamicSupervisor.start_child(Efsql.StorageCaches, spec) do
      {:ok, _pid} ->
        :ok

      :ignore ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        raise "could not start tenant cache for #{storage_id}: #{inspect(reason)}"
    end
  end

  defp root_node() do
    :erlfdb_directory.root(node_prefix: <<0xFE>>, content_prefix: <<>>)
  end

  # -- source enumeration --

  @doc """
  Enumerates the distinct sources in a tenant by prefix-hopping: read one
  key, unpack its source name, seek past that source's entire range.
  O(number of sources) round trips regardless of table sizes.
  """
  def sources(tenant, repo \\ Efsql.Repo) do
    db = Ecto.Adapters.FoundationDB.db(repo)
    {start_key, end_key} = EctoFoundationDB.Tenant.range(tenant, {@adapter_prefix})
    hop(db, tenant, start_key, end_key, [])
  end

  defp hop(db, tenant, start_key, end_key, acc) do
    case :erlfdb.get_range(db, start_key, end_key, limit: 1, snapshot: true) do
      [] ->
        acc |> Enum.reverse() |> Enum.reject(&(&1 in @internal_sources))

      [{key, _value}] ->
        source = tenant |> EctoFoundationDB.Tenant.unpack(key) |> elem(1)
        {_, source_end} = EctoFoundationDB.Tenant.range(tenant, {@adapter_prefix, source})
        hop(db, tenant, source_end, end_key, [source | acc])
    end
  end

  # -- schema sampling --

  @doc """
  Infers a `%Schema{}` for a source by sampling up to `2 * n` rows: the
  first `n` and last `n` in key order (deduplicated), plus the source's
  index metadata.
  """
  def schema(tenant, source, n \\ 100) do
    first = run(%Logical.Select{source: source, tenant: tenant, limit: n})
    last = run(%Logical.Select{source: source, tenant: tenant, order: [desc: :id], limit: n})

    rows = Enum.uniq_by(first ++ last, &Map.get(&1, :id))

    %Schema{
      source: source,
      sampled: length(rows),
      sampled_at: DateTime.utc_now(),
      fields: field_stats(rows),
      pk: pk_shape(rows),
      indexes: indexes(tenant, source)
    }
  end

  defp run(logical) do
    logical
    |> Planner.plan([])
    |> Executor.run()
  end

  defp field_stats([]), do: []

  defp field_stats(rows) do
    total = length(rows)

    rows
    |> Enum.flat_map(&Map.to_list/1)
    |> Enum.group_by(fn {field, _v} -> field end, fn {_field, v} -> v end)
    |> Enum.map(fn {field, values} ->
      # presence counts rows with a non-nil value: schema-inserted structs
      # store explicit nils, schemaless objects omit the key — treat alike
      present = Enum.reject(values, &is_nil/1)

      %{
        name: field,
        presence: length(present) / total,
        types: present |> Enum.map(&Render.type_of/1) |> Enum.frequencies(),
        examples: present |> Enum.uniq() |> Enum.take(3)
      }
    end)
    |> Enum.sort_by(fn %{name: name, presence: presence} -> {-presence, name} end)
  end

  defp pk_shape(rows) do
    rows
    |> Enum.map(&Map.get(&1, :id))
    |> Enum.map(&Render.type_of/1)
    |> Enum.uniq()
    |> case do
      [] -> nil
      [type] -> type
      _ -> :mixed
    end
  end

  def indexes(tenant, source) do
    EctoFoundationDB.Layer.Metadata.transactional(tenant, source, fn _tx, metadata ->
      for idx <- metadata.indexes, do: %{name: idx[:id], fields: idx[:fields]}
    end)
  end

  # -- schema cache --

  def cache_get(key) do
    with {:ok, bin} <- File.read(cache_path(key)),
         {@cache_version, %Schema{} = schema} <- safe_decode(bin) do
      {:ok, schema}
    else
      _ -> :miss
    end
  end

  def cache_put(key, %Schema{} = schema) do
    path = cache_path(key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :erlang.term_to_binary({@cache_version, schema}))
    :ok
  end

  defp safe_decode(bin) do
    :erlang.binary_to_term(bin, [:safe])
  rescue
    _ -> :error
  end

  defp cache_path(key) do
    hash = :crypto.hash(:sha256, :erlang.term_to_binary(key)) |> Base.encode16(case: :lower)
    Path.join([System.user_home!(), ".efsql", "cache", hash <> ".schema"])
  end
end
