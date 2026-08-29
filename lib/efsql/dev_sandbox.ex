defmodule Efsql.DevSandbox do
  @moduledoc """
  Self-contained development database: with `EFSQL_SANDBOX=1`, the
  application boots an `:erlfdb_sandbox` FoundationDB inside this BEAM
  (nothing touches any system cluster) and seeds a couple of demo tenants.
  The sandbox's data directory persists under `.erlfdb_sandbox/tui_demo/`,
  so seeding is idempotent across runs.
  """

  @subdir "tui_demo"

  defmodule User do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}

    schema "users" do
      field(:name, :string)
      field(:notes, :string)
      timestamps()
    end
  end

  defmodule Order do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}

    schema "orders" do
      field(:user_id, :string)
      field(:item, :string)
      field(:qty, :integer)
      field(:price, :float)
      timestamps()
    end
  end

  def enabled?(), do: System.get_env("EFSQL_SANDBOX") == "1"

  @doc "Called before the Repo starts: boots the sandbox db and points the Repo at it."
  def boot!() do
    _db = :erlfdb_sandbox.open(@subdir)
    cluster_file = Path.expand(Path.join([".erlfdb_sandbox", @subdir, "erlfdb.cluster"]))

    config =
      Application.get_env(:efsql, Efsql.Repo, [])
      |> Keyword.put(:cluster_file, cluster_file)

    Application.put_env(:efsql, Efsql.Repo, config)
    :ok
  end

  @doc "Called after the Repo starts: seeds demo data if not present."
  def seed!() do
    demo = EctoFoundationDB.Tenant.open!(Efsql.Repo, "demo")

    if Efsql.Repo.all(User, prefix: demo, limit: 1) == [] do
      users = [
        %User{id: "0001", name: "Alice", notes: "Lorem ipsum"},
        %User{id: "0002", name: "Bob", notes: "foobar"},
        %User{id: "0003", name: "Charles"},
        %User{id: "0004", name: "Dora", notes: "…multibyte ✓"}
      ]

      orders = [
        %Order{user_id: "0001", item: "widget", qty: 3, price: 9.99},
        %Order{user_id: "0001", item: "sprocket", qty: 1, price: 100.0},
        %Order{user_id: "0002", item: "widget", qty: 7, price: 9.99}
      ]

      for struct <- users ++ orders do
        Efsql.Repo.insert!(struct, prefix: demo)
      end
    end

    staging = EctoFoundationDB.Tenant.open!(Efsql.Repo, "staging")

    if Efsql.Repo.all(User, prefix: staging, limit: 1) == [] do
      Efsql.Repo.insert!(%User{id: "s1", name: "Stage"}, prefix: staging)
    end

    # a second storage_id so the navigator has a hierarchy to show
    Efsql.Discover.ensure_storage_cache("playground")
    _alt = EctoFoundationDB.Tenant.open!(Efsql.Repo, "scratch", storage_id: "playground")

    :ok
  end
end
