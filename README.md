# Efsql

Work in progress.

Efsql is a SQL CLI for FoundationDB, built on top of [EctoFoundationDB](https://github.com/foundationdb-beam/ecto_foundationdb).

## Build

Efsql is distributed as an Elixir release. Build it with:

```bash
mix cli
```

This produces a self-contained binary at `_build/prod/rel/efsql/bin/efsql`.

> **Note:** A fully self-contained escript is not possible at this time because of the erlfdb NIF.

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

Use `rlwrap` to enable command history and navigation:

```bash
rlwrap _build/prod/rel/efsql/bin/efsql
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

## Running the Demo

```
# In one terminal
./dev/seed

# In another
./efsql -C .ex_fdbmonitor/dev.0/etc/fdb.cluster --storage-id efsql_dev
```

## Installation

Efsql is not yet available on Hex.pm. You can install it from GitHub:

```elixir
def deps do
  [
    {:efsql, github: "foundationdb-beam/efsql"}
  ]
end
```
