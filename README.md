# Efsql

Work in progress.

Efsql is a SQL Layer for FoundationDB. It's implemented via the EctoFoundationDB Layer for Elixir.

## Usage

```bash
#!/bin/bash
mix run efsql.exs -C ../path/to/etc/fdb.cluster
```

The default cluster file is chosen using the same logic as [fdbcli's default cluster file](https://apple.github.io/foundationdb/administration.html#default-cluster-file).

```bash
~/d/efsql ❯❯❯ mix run efsql.exs -C ../path/to/etc/fdb.cluster
Connected to ../path/to/etc/fdb.cluster
[Ctrl+D to exit]
> select id, inserted_at from my_tenant_id.my_table_name;

  ┌─────────────────┬─────────────────────┐
  │ Id              │ Inserted At         │
  ├─────────────────┼─────────────────────┤
  │ trmD6RQjbPTQmMD │ 2025-05-15 22:35:38 │
  └─────────────────┴─────────────────────┘
```

Use a readline-wrapper, such as rlwrap, to enable command history:

```bash
# Enable history and navigation
~/d/efsql ❯❯❯ rlwrap mix run efsql.exs

# Some other helpful options
~/d/efsql ❯❯❯ rlwrap -ra -pgreen -f completions mix run efsql.exs
```

## Supported SQL

### Select rows

    select col_a, col_b from tenant_id.schema_name;

### Select row with primary key

Note: This is currently broken as we adapt to changes in SQL parser, and we will have to decide on a stable syntax.

    select col_a, col_b from tenant_id.schema_name where primary key = 'foobar';
    select col_a, col_b from tenant_id.schema_name where primary key >= 'bar' and primary key < 'foo';
    select col_a, col_b from tenant_id.schema_name where primary key > 'bar';
    select col_a, col_b from tenant_id.schema_name where primary key < 'foo';

Alternate

    select col_a, col_b from tenant_id.schema_name where _ = 'foobar';

### Select rows with index

    select col_a, col_b from tenant_id.schema_name where index_col = 'baz';
    select col_a, col_b from tenant_id.schema_name where index_col >= 'baz' and index_col < 'zaz';

See EctoFoundationDB's Default indexes. Since we don't require access to the Ecto.Schema, and
EctoFDB doesn't store the schema in the database, we loosen the type checking for these queries.
For example, if the indexed column is a naive_datetime, then you must query using the string
representation for the timestamp.

## escript?

Sadly, it's not possible to have a self-contained escript at this time because of the erlfdb NIF.

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `efsql` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:efsql, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/efsql>.
