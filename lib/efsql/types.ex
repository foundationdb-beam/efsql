defmodule Efsql.Types do
  @moduledoc """
  Typed literals in the where clause.

  A SQL literal is a string, number, or boolean. Elixir terms with no SQL
  counterpart are written as a literal with a type annotation, using the
  PostgreSQL cast operator or its standard SQL spelling:

      where status = 'active'::atom
      where status = cast('active' as atom)
      where status in ('active'::atom, 'pending'::atom)

  Both forms parse to `cast(type, value)`, which converts the already-parsed
  literal into the Elixir term the adapter compares against. Type names are
  case-insensitive.

  To add a type, add its name to `@types` and a `cast/2` clause for it.
  """

  alias Efsql.Exception.Unsupported

  @types ~w[atom]

  def types(), do: @types

  # Atoms are created, not looked up: the value may only exist in stored
  # data this node has not decoded yet, and the adapter needs the term
  # itself to build index and primary-key ranges.
  def cast("atom", value) when is_binary(value), do: String.to_atom(value)

  def cast(type, value) when type in @types do
    raise Unsupported, "Cannot cast #{inspect(value)} to #{type}"
  end

  def cast(type, _value) do
    raise Unsupported, "Unknown type '#{type}'. Supported types: #{Enum.join(@types, ", ")}"
  end
end
