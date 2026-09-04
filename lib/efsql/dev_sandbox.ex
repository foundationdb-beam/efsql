defmodule Efsql.DevSandbox do
  @moduledoc """
  Self-contained development database: with `EFSQL_SANDBOX=1`, the
  application boots an `:erlfdb_sandbox` FoundationDB inside this BEAM
  (nothing touches any system cluster) and seeds demo tenants.

  The data is deliberately messy, because efsql exists to answer "what is
  really in my database": fields present on only some rows, a mix of value
  types, non-printable binaries, unicode, nested maps and lists, both plain
  and versionstamp primary keys, and enough rows that limits, ordering and
  scrolling matter.

  Data lives under `.erlfdb_sandbox/` and is seeded once. Bumping
  `@seed_version` discards the old directory and rebuilds, so the demo always
  matches this file.
  """

  alias EctoFoundationDB.Versionstamp

  # Plain Elixir structs stored inside a row, to show how the TUI renders
  # nested structures: elided in table cells, expanded in the inspector.
  defmodule Address do
    @moduledoc false
    defstruct [:street, :city, :country, :postcode, :geo]
  end

  defmodule Profile do
    @moduledoc false
    defstruct [:display_name, :address, :links, :flags, :quota, :last_seen]
  end

  @seed_version 3
  # The seed version is part of the directory name, so bumping it yields both a
  # fresh database and a fresh cluster-file path. That path is part of efsql's
  # schema cache key, so cached schemas can never go stale against a rebuild.
  @subdir "tui_demo_v#{@seed_version}"

  defmodule User do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}

    schema "users" do
      field(:name, :string)
      field(:email, :string)
      field(:city, :string)
      field(:plan, :string)
      field(:notes, :string)
      field(:bio, :string)
      field(:age, :integer)
      field(:score, :float)
      field(:active, :boolean)
      field(:avatar, :binary)
      field(:prefs, :map)
      field(:profile, :map)
      field(:tags, {:array, :string})
      field(:signup, :naive_datetime)
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
      field(:status, :string)
      field(:qty, :integer)
      field(:price, :float)
      field(:placed_at, :naive_datetime)
      timestamps()
    end
  end

  defmodule Product do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:id, :binary_id, autogenerate: true}

    schema "products" do
      field(:sku, :string)
      field(:name, :string)
      field(:category, :string)
      field(:price, :float)
      field(:in_stock, :boolean)
    end
  end

  # Versionstamp primary key partitioned by user_id: exercises efsql's
  # `where _ = ('<user-id>', *)` partition scans.
  defmodule Session do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:id, Versionstamp, partition_by: :user_id, autogenerate: false}

    schema "sessions" do
      field(:user_id, :string)
      field(:ip, :string)
      field(:agent, :string)
    end
  end

  # Plain versionstamp primary key: an append-only log, ordered by insertion.
  defmodule Event do
    @moduledoc false
    use Ecto.Schema
    @primary_key {:id, Versionstamp, autogenerate: false}

    schema "events" do
      field(:kind, :string)
      field(:user_id, :string)
      field(:payload, :string)
      timestamps()
    end
  end

  defmodule Migration do
    @moduledoc false
    use EctoFoundationDB.Migration
    alias Efsql.DevSandbox.Event
    alias Efsql.DevSandbox.Order
    alias Efsql.DevSandbox.Product
    alias Efsql.DevSandbox.User

    @impl true
    def change() do
      [
        create(index(User, [:name])),
        create(index(User, [:city])),
        # compound: `where city = '..' and age > ..` rides the equality prefix
        create(index(User, [:city, :age])),
        create(index(Order, [:user_id])),
        create(index(Order, [:status])),
        create(index(Product, [:category])),
        create(index(Event, [:kind]))
      ]
    end
  end

  def enabled?(), do: System.get_env("EFSQL_SANDBOX") == "1"

  @doc """
  Indexes for the demo tenants. Empty unless the sandbox is enabled, so
  efsql never migrates a real database.
  """
  def migrations() do
    if enabled?(), do: [{0, Migration}], else: []
  end

  @doc "Called before the Repo starts: boots the sandbox db and points the Repo at it."
  def boot!() do
    discard_old_sandboxes!()
    dir = Path.expand(Path.join(".erlfdb_sandbox", @subdir))

    _db = :erlfdb_sandbox.open(@subdir)

    config =
      Application.get_env(:efsql, Efsql.Repo, [])
      |> Keyword.put(:cluster_file, Path.join(dir, "erlfdb.cluster"))

    Application.put_env(:efsql, Efsql.Repo, config)
    :ok
  end

  defp discard_old_sandboxes!() do
    Path.wildcard(".erlfdb_sandbox/tui_demo*")
    |> Enum.reject(&(Path.basename(&1) == @subdir))
    |> Enum.each(&File.rm_rf!/1)
  end

  @doc "Called after the Repo starts: seeds the demo tenants if not already seeded."
  def seed!() do
    demo = EctoFoundationDB.Tenant.open!(Efsql.Repo, "demo")

    if empty?(demo, User) do
      # Deterministic, so the demo is identical on every machine.
      :rand.seed(:exsss, {17, 23, 42})

      users = users()
      insert_all(demo, users)
      insert_all(demo, products())
      insert_all(demo, orders(users))
      insert_versionstamped(demo, Session, sessions(users))
      insert_versionstamped(demo, Event, events(users))
    end

    staging = EctoFoundationDB.Tenant.open!(Efsql.Repo, "staging")

    if empty?(staging, User) do
      insert_all(staging, [
        %User{name: "Stage One", email: "one@staging.test", city: "Portland", active: true},
        %User{name: "Stage Two", email: "two@staging.test", city: "Portland", active: false}
      ])
    end

    # A tenant with no data at all, to exercise empty states.
    _empty = EctoFoundationDB.Tenant.open!(Efsql.Repo, "empty")

    # A second storage_id, so the navigator has a hierarchy to show.
    Efsql.Discover.ensure_storage_cache("playground")
    _scratch = EctoFoundationDB.Tenant.open!(Efsql.Repo, "scratch", storage_id: "playground")

    :ok
  end

  defp empty?(tenant, schema) do
    Efsql.Repo.all(schema, prefix: tenant, limit: 1) == []
  end

  defp insert_all(tenant, structs) do
    structs
    |> Enum.chunk_every(100)
    |> Enum.each(fn chunk ->
      Efsql.Repo.transactional(tenant, fn ->
        Enum.each(chunk, &Efsql.Repo.insert!/1)
      end)
    end)
  end

  defp insert_versionstamped(tenant, schema, structs) do
    structs
    |> Enum.chunk_every(100)
    |> Enum.each(fn chunk ->
      future =
        Efsql.Repo.transactional(tenant, fn ->
          Efsql.Repo.async_insert_all!(schema, chunk)
        end)

      Efsql.Repo.await(future)
    end)
  end

  # -- generated data --

  @first ~w[Alice Bob Charles Dora Ewan Farah Gus Hana Ivan Junko Kai Lena
            Mateo Nadia Omar Priya Quinn Rosa Sven Tara Uma Viktor Wren
            Xiu Yusuf Zara Ada Bruno Cleo Dmitri]
  @last ~w[Alvarez Byrne Chen Dupont Eriksen Fischer Gupta Haddad Ibrahim
           Jensen Kowalski Lindqvist Moreau Novak Okafor Petrov]
  @cities ~w[Boston Berlin Lisbon Nairobi Osaka Portland Reykjavik Santiago
             Toronto Valencia]
  @plans ~w[free pro enterprise]
  @items ~w[widget sprocket gasket flange bearing bracket coupling washer]
  @categories ~w[hardware tooling fasteners electronics]
  @statuses ~w[pending paid shipped delivered refunded]
  @kinds ~w[login logout purchase view error signup]

  defp users() do
    for i <- 1..60 do
      first = Enum.at(@first, rem(i * 7, length(@first)))
      last = Enum.at(@last, rem(i * 5, length(@last)))
      name = "#{first} #{last}"

      %User{
        id: user_id(i),
        name: name,
        email: String.downcase("#{first}.#{last}@example.com"),
        city: city(i),
        plan: Enum.at(@plans, rem(i, 3)),
        age: 21 + rem(i * 13, 45),
        score: Float.round(:rand.uniform() * 100, 2),
        active: rem(i, 4) != 0,
        signup: days_ago(400 - i * 5),
        # Sparse fields: absent on many rows, which is what presence % shows.
        notes: if(rem(i, 3) == 0, do: "Lorem ipsum dolor sit amet #{i}"),
        bio: if(rem(i, 5) == 0, do: "Ávid ünicode ✓ user — #{name} 日本語"),
        avatar: if(rem(i, 7) == 0, do: :crypto.strong_rand_bytes(24)),
        prefs: if(rem(i, 4) == 0, do: prefs(i)),
        profile: if(rem(i, 3) == 1, do: profile(i, name, city(i))),
        tags: if(rem(i, 6) == 0, do: Enum.take_random(~w[beta vip staff early], 2))
      }
    end
  end

  defp products() do
    for i <- 1..30 do
      %Product{
        sku: "SKU-" <> String.pad_leading("#{i}", 4, "0"),
        name:
          "#{Enum.at(@items, rem(i, length(@items)))} #{Enum.at(~w[mk1 mk2 mk3 pro], rem(i, 4))}",
        category: Enum.at(@categories, rem(i, length(@categories))),
        price: Float.round(5 + :rand.uniform() * 200, 2),
        in_stock: rem(i, 5) != 0
      }
    end
  end

  defp orders(users) do
    for i <- 1..250 do
      user = Enum.at(users, rem(i * 11, length(users)))

      %Order{
        user_id: user.id,
        item: Enum.at(@items, rem(i * 3, length(@items))),
        status: Enum.at(@statuses, rem(i * 7, length(@statuses))),
        qty: 1 + rem(i, 9),
        price: Float.round(5 + :rand.uniform() * 300, 2),
        placed_at: days_ago(rem(i * 3, 365))
      }
    end
  end

  defp sessions(users) do
    for i <- 1..120 do
      user = Enum.at(users, rem(i * 5, length(users)))

      %Session{
        user_id: user.id,
        ip: "10.#{rem(i, 250)}.#{rem(i * 3, 250)}.#{rem(i * 7, 250)}",
        agent: Enum.at(~w[firefox safari chrome curl efsql], rem(i, 5))
      }
    end
  end

  defp events(users) do
    for i <- 1..300 do
      user = Enum.at(users, rem(i * 13, length(users)))

      %Event{
        kind: Enum.at(@kinds, rem(i * 5, length(@kinds))),
        user_id: user.id,
        payload: ~s({"seq":#{i},"ok":#{rem(i, 9) != 0}})
      }
    end
  end

  # A deliberately deep map: several levels, and a list of maps.
  defp prefs(i) do
    %{
      "theme" => Enum.at(~w[dark light system], rem(i, 3)),
      "locale" => Enum.at(~w[en-US de-DE pt-PT ja-JP], rem(i, 4)),
      "notifications" => %{
        "email" => rem(i, 2) == 0,
        "sms" => false,
        "digest" => %{
          "cadence" => Enum.at(~w[daily weekly never], rem(i, 3)),
          "hour" => rem(i, 24)
        }
      },
      "editor" => %{
        "font" => Enum.at(["Berkeley Mono", "Iosevka", "SF Mono"], rem(i, 3)),
        "size" => 11 + rem(i, 5),
        "keymap" => Enum.at(~w[vim emacs default], rem(i, 3))
      },
      "recent" => for(n <- 1..3, do: %{"path" => "/orders/#{i * n}", "pinned" => rem(n, 2) == 0})
    }
  end

  # A struct holding another struct, a list of maps, a MapSet and a nested map.
  defp profile(i, name, city) do
    %Profile{
      display_name: name,
      address: %Address{
        street: "#{i} #{Enum.at(~w[Alder Birch Cedar Elm Maple], rem(i, 5))} Street",
        city: city,
        country: Enum.at(~w[US DE PT KE JP CA], rem(i, 6)),
        postcode: "#{10_000 + i * 7}",
        geo: %{
          lat: Float.round(-60 + :rand.uniform() * 120, 4),
          lon: Float.round(-180 + :rand.uniform() * 360, 4)
        }
      },
      links: [
        %{
          "rel" => "homepage",
          "url" => "https://example.com/~#{String.downcase(String.replace(name, " ", "."))}"
        },
        %{"rel" => "avatar", "url" => "https://cdn.example.com/a/#{i}.png"}
      ],
      flags: MapSet.new(Enum.take_random(~w[verified beta staff trial]a, 2)),
      quota: %{
        "storage" => %{"used_mb" => i * 37, "limit_mb" => 10_000},
        "api" => %{"used" => i * 113, "limit" => 100_000, "window" => "1h"}
      },
      last_seen: days_ago(rem(i, 30))
    }
  end

  defp city(i), do: Enum.at(@cities, rem(i * 3, length(@cities)))

  defp user_id(i), do: "u" <> String.pad_leading("#{i}", 4, "0")

  defp days_ago(n) do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(-n * 86_400, :second)
    |> NaiveDateTime.truncate(:second)
  end
end
