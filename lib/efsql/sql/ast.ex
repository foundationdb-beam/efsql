defmodule Efsql.SQL.AST do
  @moduledoc """
  The syntax tree `Efsql.SQL.Parser` produces. It records what the SQL text
  says, not what efsql can execute: `OR`, `NOT IN` and the like parse fine
  and are rejected later, in `Efsql.Parser`, with a message about the
  feature rather than the syntax.

  Names are strings. Unquoted names are folded to lower case; quoted names
  keep their case.
  """

  defmodule Select do
    @moduledoc "A `SELECT` statement."

    @type t :: %__MODULE__{
            fields: :star | [String.t() | Efsql.SQL.AST.aggregate()],
            from: [String.t(), ...],
            where: Efsql.SQL.AST.expr() | nil,
            group_by: [String.t()],
            order_by: [{String.t() | Efsql.SQL.AST.aggregate(), :asc | :desc}],
            limit: non_neg_integer() | nil
          }

    # `from` holds the dotted name's parts: [table], [tenant, table] or
    # [storage_id, tenant, table].
    defstruct fields: :star, from: [], where: nil, group_by: [], order_by: [], limit: nil
  end

  @typedoc """
  An aggregate call in the select list or ORDER BY:
  `{:aggregate, function, argument, alias}`. The function is any lower-case
  name (`count`, `sum`, ...), the argument a field name or `:star`, and the
  alias the `AS` name or `nil`.
  """
  @type aggregate :: {:aggregate, String.t(), String.t() | :star, String.t() | nil}

  @typedoc """
  An expression.

    * `{:column, name}`
    * `{:literal, value}` — a string, integer, float, boolean, or `nil`
      for `NULL`
    * `{:cast, expr, type}` — `expr::type` or `CAST(expr AS type)`; `type`
      is a lower-case name, with `timestamp with time zone` read as
      `timestamptz`
    * `{:tuple, [expr | :star]}` — `(a, b, ...)`, whose elements may be `*`
    * `{:and, left, right}`, `{:or, left, right}`, `{:not, expr}`
    * `{:compare, op, left, right}` — `op` is `:=`, `:<>`, `:<`, `:>`,
      `:<=` or `:>=`; `!=` reads as `:<>`
    * `{:between, expr, low, high, negated?}`
    * `{:in, expr, [expr], negated?}`
    * `{:like, expr, pattern, negated?}`, `{:ilike, expr, pattern, negated?}`
    * `{:is_null, expr, negated?}` — also `ISNULL` and `NOTNULL`
  """
  @type expr ::
          {:column, String.t()}
          | {:literal, String.t() | number() | boolean() | nil}
          | {:cast, expr(), String.t()}
          | {:tuple, [expr() | :star]}
          | {:and | :or, expr(), expr()}
          | {:not, expr()}
          | {:compare, := | :<> | :< | :> | :<= | :>=, expr(), expr()}
          | {:between, expr(), expr(), expr(), boolean()}
          | {:in, expr(), [expr()], boolean()}
          | {:like | :ilike, expr(), expr(), boolean()}
          | {:is_null, expr(), boolean()}
end
