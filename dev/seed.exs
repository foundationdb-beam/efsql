#!/usr/bin/env elixir

# Dev seed script. Run via the wrapper (which sets ERL_FLAGS=-name):
#   mix seed        (calls dev/seed shell script)
#   ./dev/seed      (directly)
#
# The node must be named at VM startup — LocalCluster calls net_kernel.start
# mid-session which breaks OTP's code server if the node was unnamed.
#
# Starts a local FDB sandbox, seeds it with test data, then waits for
# Enter so you can run ./efsql against it.
#
# Each run is idempotent — tenants are wiped and re-seeded.

alias ExFdbmonitor.Sandbox

Sandbox.start()

sandbox = Sandbox.Single.checkout("dev", starting_port: 5050)
cluster_file = Sandbox.cluster_file("dev", 0)

# ---------------------------------------------------------------------------
# Schemas
# ---------------------------------------------------------------------------

defmodule Seed.User do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "users" do
    field(:name, :string)
    field(:email, :string)
    field(:role, :string)
    field(:department, :string)
    field(:notes, :string)
    timestamps()
  end
end

defmodule Seed.Order do
  use Ecto.Schema

  @primary_key {:id, EctoFoundationDB.Versionstamp, partition_by: :user_id, autogenerate: false}

  schema "orders" do
    field(:user_id, :binary_id)
    field(:product, :string)
    field(:status, :string)
    field(:ref, :string)
    timestamps()
  end
end

# ---------------------------------------------------------------------------
# Migrations
# ---------------------------------------------------------------------------

defmodule Seed.Migrations.V0 do
  use EctoFoundationDB.Migration

  def change do
    [
      create(index(Seed.User, [:name])),
      create(index(Seed.User, [:email])),
      create(index(Seed.User, [:role])),
      create(index(Seed.User, [:department]))
    ]
  end
end

defmodule Seed.Migrations.V1 do
  use EctoFoundationDB.Migration

  def change do
    [
      create(index(Seed.Order, [:product])),
      create(index(Seed.Order, [:status]))
    ]
  end
end

# ---------------------------------------------------------------------------
# Repo
# ---------------------------------------------------------------------------

defmodule Seed.Repo do
  use Ecto.Repo, otp_app: :seed, adapter: Ecto.Adapters.FoundationDB
  use EctoFoundationDB.Migrator

  @impl true
  def migrations do
    [
      {0, Seed.Migrations.V0},
      {1, Seed.Migrations.V1}
    ]
  end
end

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

storage_id = "efsql_dev"

Application.put_env(:seed, Seed.Repo,
  cluster_file: cluster_file,
  storage_id: storage_id
)

Application.ensure_all_started(:ecto_foundationdb)
{:ok, _} = Seed.Repo.start_link()

IO.puts("Connected to #{cluster_file} (storage_id: #{storage_id})\n")

# ---------------------------------------------------------------------------
# Seed data
# ---------------------------------------------------------------------------

alias EctoFoundationDB.Tenant

tenants = %{
  "acme" => %{
    users: [
      %{
        name: "Alice Anderson",
        email: "alice@acme.com",
        role: "admin",
        department: "engineering",
        notes: "Founder"
      },
      %{
        name: "Bob Baker",
        email: "bob@acme.com",
        role: "manager",
        department: "engineering",
        notes: "Tech lead"
      },
      %{name: "Carol Clark", email: "carol@acme.com", role: "user", department: "sales"},
      %{
        name: "Dave Davis",
        email: "dave@acme.com",
        role: "user",
        department: "sales",
        notes: "Account exec"
      },
      %{name: "Eve Evans", email: "eve@acme.com", role: "manager", department: "hr"},
      %{name: "Frank Foster", email: "frank@acme.com", role: "user", department: "engineering"},
      %{name: "Grace Green", email: "grace@acme.com", role: "user", department: "engineering"}
    ],
    orders: [
      %{product: "Widget Pro", status: "shipped", ref: "ORD-001"},
      %{product: "Widget Pro", status: "pending", ref: "ORD-002"},
      %{product: "Gadget Plus", status: "shipped", ref: "ORD-003"},
      %{product: "Gadget Plus", status: "cancelled", ref: "ORD-004"},
      %{product: "Gizmo Ultra", status: "pending", ref: "ORD-005"}
    ]
  },
  "globex" => %{
    users: [
      %{name: "Hank Hill", email: "hank@globex.com", role: "admin", department: "operations"},
      %{
        name: "Iris Irving",
        email: "iris@globex.com",
        role: "user",
        department: "research",
        notes: "PhD"
      },
      %{name: "Jack Jones", email: "jack@globex.com", role: "manager", department: "research"},
      %{name: "Kate King", email: "kate@globex.com", role: "user", department: "operations"}
    ],
    orders: [
      %{product: "Widget Pro", status: "shipped", ref: "G-001"},
      %{product: "Gizmo Ultra", status: "shipped", ref: "G-002"},
      %{product: "Gizmo Ultra", status: "pending", ref: "G-003"}
    ]
  },
  "umbrella" => %{
    users: [
      %{
        name: "Leo Lambert",
        email: "leo@umbrella.com",
        role: "admin",
        department: "security",
        notes: "Director"
      },
      %{name: "Mia Morris", email: "mia@umbrella.com", role: "user", department: "research"},
      %{name: "Nick Nash", email: "nick@umbrella.com", role: "user", department: "research"},
      %{
        name: "Olivia Owen",
        email: "olivia@umbrella.com",
        role: "manager",
        department: "security"
      },
      %{name: "Paul Park", email: "paul@umbrella.com", role: "user", department: "logistics"}
    ],
    orders: [
      %{product: "Hazmat Kit", status: "shipped", ref: "U-001"},
      %{product: "Hazmat Kit", status: "shipped", ref: "U-002"},
      %{product: "Bio Container", status: "pending", ref: "U-003"},
      %{product: "Bio Container", status: "cancelled", ref: "U-004"}
    ]
  }
}

for {tenant_id, data} <- tenants do
  IO.write("  seeding #{tenant_id}... ")

  tenant = Tenant.open_empty!(Seed.Repo, tenant_id)

  inserted_users =
    Seed.Repo.transactional(
      tenant,
      fn ->
        for attrs <- data.users do
          Seed.Repo.insert!(struct(Seed.User, attrs))
        end
      end
    )

  # Assign orders round-robin across the inserted users
  user_ids = Enum.map(inserted_users, & &1.id)

  order_attrs =
    data.orders
    |> Enum.with_index()
    |> Enum.map(fn {attrs, i} ->
      user_id = Enum.at(user_ids, rem(i, length(user_ids)))
      Map.put(attrs, :user_id, user_id)
    end)

  orders = for order_attr <- order_attrs, do: struct(Seed.Order, order_attr)

  future =
    Seed.Repo.transactional(
      tenant,
      fn -> Seed.Repo.async_insert_all!(Seed.Order, orders) end
    )

  Seed.Repo.await(future)

  IO.puts("#{length(data.users)} users, #{length(data.orders)} orders")
end

# Grab a sample user id for the partition query example
sample_user_id =
  Seed.Repo.transactional(
    Tenant.open!(Seed.Repo, "acme"),
    fn -> Seed.Repo.all(Seed.User, limit: 1) end
  )
  |> hd()
  |> Map.fetch!(:id)

IO.puts("""

Done. Connect with:

  ./efsql -C #{cluster_file} --storage-id #{storage_id}

Try these queries:

  -- all users in a tenant
  select * from acme.users;
  select id, name, email, role, department from acme.users;

  -- filter by indexed field
  select id, name, email from acme.users where role = 'admin';
  select id, name, department from acme.users where department = 'engineering';

  -- range on primary key
  select id, name from acme.users where _ > '0' limit 3;

  -- orders (partitioned versionstamp pk)
  select id, product, status, ref from acme.orders;

  -- all orders for a user (full partition scan, select * supported here)
  select * from acme.orders where _ = ('#{sample_user_id}', *);
  select id, product, status, ref from acme.orders where _ = ('#{sample_user_id}', *);

  -- orders for a user from a checkpoint (replace N with an id from above)
  select id, product, ref from acme.orders where _ >= ('#{sample_user_id}', N);

  -- cross-tenant: same query, different data
  select id, name, role from globex.users;
  select id, name, role from umbrella.users where role = 'admin';

  -- explicit storage_id prefix (storage_id.tenant.table)
  select * from #{storage_id}.acme.users;
""")

IO.gets("Press Enter to stop FDB...")

Sandbox.Single.checkin(sandbox)
