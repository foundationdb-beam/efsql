# Efsql

Work in progress.

Efsql is a SQL CLI for FoundationDB, built on top of [EctoFoundationDB](https://github.com/foundationdb-beam/ecto_foundationdb).

## Requirements

efsql needs the **FoundationDB client library** (`libfdb_c`) on the machine
where it runs. It is not bundled, and Homebrew does not package it — install it
from the [FoundationDB releases](https://github.com/apple/foundationdb/releases).
Released efsql binaries are compiled against FDB API version 730, so the client
must be **7.3 or newer**.

Building from source additionally needs Elixir and Erlang/OTP. `mix.exs`
requires Elixir `~> 1.17`; efsql is developed and tested on Elixir 1.19 /
OTP 28, which is also what the release builds use.

## Installation

Released binaries bundle their own Erlang runtime, so Elixir and OTP are only
needed to build from source.

> **Note:** the download links below become live with the first tagged
> release. Until then, [build from source](#build-from-source).

### macOS

Install the FoundationDB client (there is no client-only package for macOS, so
this installs the server too; you do not have to run it):

```bash
curl -LO https://github.com/apple/foundationdb/releases/download/7.3.69/FoundationDB-7.3.69_arm64.pkg
```

```bash
sudo installer -pkg FoundationDB-7.3.69_arm64.pkg -target /
```

On an Intel Mac, use the `_x86_64.pkg` asset instead. Then install efsql:

```bash
brew install foundationdb-beam/tap/efsql
```

### Linux

Install the FoundationDB client, then efsql. On x86_64:

```bash
curl -LO https://github.com/apple/foundationdb/releases/download/7.3.69/foundationdb-clients_7.3.69-1_amd64.deb
```

```bash
sudo dpkg -i foundationdb-clients_7.3.69-1_amd64.deb
```

```bash
VERSION=0.1.0 && curl -LO https://github.com/foundationdb-beam/efsql/releases/download/v${VERSION}/efsql_${VERSION}_amd64.deb
```

```bash
sudo dpkg -i efsql_0.1.0_amd64.deb
```

On arm64, substitute `aarch64` in the FoundationDB asset name and `arm64` in
the efsql one.

### Other platforms, or no package manager

Tarballs are published for macOS and Linux on both architectures. They unpack
to a self-contained directory; put `bin/efsql` on your `PATH` (a symlink is
fine — it resolves its own location):

```bash
VERSION=0.1.0 && curl -LO https://github.com/foundationdb-beam/efsql/releases/download/v${VERSION}/efsql-${VERSION}-linux-x86_64.tar.gz
```

```bash
tar xzf efsql-0.1.0-linux-x86_64.tar.gz
```

### Verify the installation

```bash
efsql --check
```

This loads the FoundationDB client and reports whether it is usable, which
separates a packaging problem from a connection problem.

## Build from source

```bash
mix deps.get
```

```bash
MIX_ENV=prod mix release
```

This produces a self-contained release at `_build/prod/rel/efsql/bin/efsql`.

The build compiles the erlfdb NIF, which detects the FoundationDB API version
by running `fdbcli`. If `fdbcli` is not on your `PATH`, set the version
explicitly:

```bash
ERLFDB_COMPILE_API_VERSION=730 MIX_ENV=prod mix release
```

To run against a database without building a release:

```bash
mix run -e 'Efsql.Cli.main([])'
```

> **Note:** A fully self-contained escript is not possible because of the erlfdb NIF.

## Usage

```bash
_build/prod/rel/efsql/bin/efsql [-C cluster_file] [--storage-id id] [--debug]
```

The default cluster file is chosen using the same logic as [fdbcli](https://apple.github.io/foundationdb/administration.html#default-cluster-file):

1. `$FDB_CLUSTER_FILE` environment variable
2. `./fdb.cluster` in the current directory
3. `/usr/local/etc/foundationdb/fdb.cluster`

### Options

| Flag | Description |
|------|-------------|
| `-C`, `--cluster-file PATH` | Path to `fdb.cluster` file |
| `--storage-id ID` | FoundationDB storage ID |
| `--debug` | Print the computed Repo call before each result |
| `--no-tui` | Use the line-based REPL instead of the full-screen TUI |
| `--check` | Verify the FoundationDB client library loads, then exit |
| `-V`, `--version` | Show the version |
| `-h`, `--help` | Show help |

### Example session

```
$ _build/prod/rel/efsql/bin/efsql -C /etc/foundationdb/fdb.cluster
Connected to /etc/foundationdb/fdb.cluster
[Ctrl+D to exit]
> select id, product, status from acme.orders;
╭──────────────────────┬─────────────┬───────────╮
│ id                   │ product     │ status    │
├──────────────────────┼─────────────┼───────────┤
│ 22348699227647901699 │ Gadget Plus │ cancelled │
╰──────────────────────┴─────────────┴───────────╯
(1 rows)
```


## Supported SQL

All queries require at minimum a `tenant_id.table_name` form in the `FROM` clause. Column names that are reserved SQL words (e.g. `ref`) are supported.

### Storage IDs

FoundationDB data is organized by storage ID. When multiple storage IDs are in use (e.g. one per product tier or user class), you can address them within a single session using a three-part `storage_id.tenant_id.table_name` form:

```sql
select * from customer.acme.orders;
select * from admins.engineering.users;
```

The two-part `tenant_id.table_name` form continues to use the storage ID set at startup via `--storage-id` (or the default if none was given).

### Select rows

```sql
select col_a, col_b from tenant_id.table_name;
```

### Filter by primary key

```sql
-- exact match
select col_a, col_b from tenant_id.table_name where _ = 'foobar';

-- range
select col_a, col_b from tenant_id.table_name where _ >= 'bar' and _ < 'foo';
select col_a, col_b from tenant_id.table_name where _ > 'bar';
select col_a, col_b from tenant_id.table_name where _ < 'foo';
select col_a, col_b from tenant_id.table_name where _ between 'bar' and 'foo';
```

### Filter by partitioned versionstamp primary key

For schemas with a versionstamp primary key partitioned by a field (e.g. `partition_by: :user_id`), use a tuple `('partition-value', ...)` syntax:

```sql
-- scan all rows in a partition (select * is supported here)
select * from tenant_id.table_name where _ = ('user-uuid', *);
select col_a, col_b from tenant_id.table_name where _ = ('user-uuid', *);

-- range within a partition (N is a versionstamp integer from the id column)
select col_a, col_b from tenant_id.table_name
  where _ >= ('user-uuid', 22348699227647901699)
    and _ <  ('user-uuid', 22348699227647901800);
```

`SELECT *` is supported for any query that doesn't use an index (full table scans, primary key lookups, and partition range scans). It is not supported for index queries.

### Filter by index

```sql
-- exact match on an indexed column
select col_a, col_b from tenant_id.table_name where index_col = 'baz';

-- range on an indexed column
select col_a, col_b from tenant_id.table_name where index_col >= 'baz' and index_col < 'zaz';
select col_a, col_b from tenant_id.table_name where index_col between 'baz' and 'zaz';
```

Since efsql doesn't have access to the Ecto schema, type checking is loosened. For example, a `naive_datetime` indexed column must be queried using its string representation.

### Limit

```sql
select col_a, col_b from tenant_id.table_name limit 100;
```

If no `LIMIT` is specified, efsql caps results at 15 rows and indicates when more are available.

## Running the demo

`EFSQL_SANDBOX=1` boots a throwaway FoundationDB inside the same BEAM and seeds
it with demo tenants, so it never touches a real cluster:

```bash
EFSQL_SANDBOX=1 ELIXIR_ERL_OPTIONS='+Bi' mix run -e 'Efsql.Cli.main([])'
```

The demo has two storage ids and several tenants; `demo` holds ~760 rows across
`users`, `orders`, `products`, `sessions` (a partitioned versionstamp key) and
`events`. Press `?` inside the TUI for the query reference.

Data persists under `.erlfdb_sandbox/`; delete that directory to reseed. The
`+Bi` flag stops Ctrl-C from dropping the VM into its BREAK menu, which raw
mode would otherwise expose.
