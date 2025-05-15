# Efsql

Work in progress.

Efsql is a SQL Layer for FoundationDB. It's implemented via the EctoFoundationDB Layer for Elixir.

## Usage

```bash
#!/bin/bash
mix run efsql.exs -C ../path/to/etc/fdb.cluster
```

The default cluster file is chosen using the same logic as [fdbcli's default cluster file](https://apple.github.io/foundationdb/administration.html#default-cluster-file).

```
~/d/efsql ❯❯❯ ./dev-efsql                                                                                                                                                ✘ 126
Compiling 1 file (.ex)
Generated efsql app
[cluster_file: "../path/to/etc/fdb.cluster"]
> select id, inserted_at from my_tenant_id.my_table_name;

  ┌─────────────────┬─────────────────────┐
  │ Id              │ Inserted At         │
  ├─────────────────┼─────────────────────┤
  │ trmD6RQjbPTQmMD │ 2025-05-15 22:35:38 │
  └─────────────────┴─────────────────────┘
```

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
