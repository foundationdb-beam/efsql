defmodule Efsql.Types do
  @moduledoc """
  Typed literals in the where clause, and how their values compare.

  A SQL literal is a string, number, or boolean. Elixir terms with no SQL
  counterpart are written as a literal with a type annotation, using the
  PostgreSQL cast operator or its standard SQL spelling:

      where status = 'active'::atom
      where status = cast('active' as atom)
      where inserted_at >= '2024-03-01 12:00:00'::timestamp
      where birthday = '2024-03-01'::date

  Both forms parse to `cast(type, value)`, which converts the already-parsed
  literal into the Elixir term the adapter compares against. Type names are
  case-insensitive.

  Elixir has two datetime types, and Ecto stores each as-is, so each gets
  its own SQL type. Use the one matching the column's Ecto type:

    * `timestamp` (or `naive_datetime`) — a `NaiveDateTime`, for
      `:naive_datetime` and `:naive_datetime_usec` fields. A time zone
      offset in the literal is rejected rather than silently dropped.
    * `timestamptz` (or `utc_datetime`) — a UTC `DateTime`, for
      `:utc_datetime` and `:utc_datetime_usec` fields. An offset in the
      literal is applied; without one the literal is taken as UTC.

  Either accepts a bare date (`'2024-03-01'`) as midnight.

  `date` is a `Date` and `time` a `Time` (for `:time` and `:time_usec`
  fields), both in ISO 8601.

  Numbers need no annotation: a numeric literal compares by value against a
  `Decimal` field.

  To add a type, add its name to `@types` and a `cast/2` clause for it, plus
  `compare/2` and `index_key/1` clauses if its terms need them.
  """

  alias Efsql.Exception.Unsupported

  @aliases %{"naive_datetime" => "timestamp", "utc_datetime" => "timestamptz"}
  @types ~w[atom timestamp timestamptz date time]

  def types(), do: @types ++ Map.keys(@aliases)

  def cast(type, value), do: do_cast(Map.get(@aliases, type, type), type, value)

  # Atoms are created, not looked up: the value may only exist in stored
  # data this node has not decoded yet, and the adapter needs the term
  # itself to build index and primary-key ranges.
  defp do_cast("atom", _as, value) when is_binary(value), do: String.to_atom(value)

  defp do_cast("timestamp", as, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} ->
        raise Unsupported,
              "#{inspect(value)} has a time zone offset, which #{as} would drop; " <>
                "use timestamptz for a DateTime"

      {:error, _} ->
        naive_datetime!(value, as)
    end
  end

  defp do_cast("timestamptz", as, value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _} -> value |> naive_datetime!(as) |> DateTime.from_naive!("Etc/UTC")
    end
  end

  defp do_cast("date", as, value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      {:error, _} -> raise Unsupported, "Cannot cast #{inspect(value)} to #{as}"
    end
  end

  defp do_cast("time", as, value) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> time
      {:error, _} -> raise Unsupported, "Cannot cast #{inspect(value)} to #{as}"
    end
  end

  defp do_cast(type, as, value) when type in @types do
    raise Unsupported, "Cannot cast #{inspect(value)} to #{as}"
  end

  defp do_cast(_type, as, _value) do
    raise Unsupported, "Unknown type '#{as}'. Supported types: #{Enum.join(types(), ", ")}"
  end

  defp naive_datetime!(value, as) do
    with {:error, _} <- NaiveDateTime.from_iso8601(value),
         {:ok, date} <- Date.from_iso8601(value) do
      NaiveDateTime.new!(date, ~T[00:00:00])
    else
      {:ok, naive} -> naive
      {:error, _} -> raise Unsupported, "Cannot cast #{inspect(value)} to #{as}"
    end
  end

  @doc """
  Orders two field values, `:lt`, `:eq` or `:gt`. Dates and times compare
  chronologically (term order would compare their struct fields, and term
  equality their precision), and a `Decimal` by value against another
  `Decimal` or a number (term order puts every number below every map);
  everything else by Erlang term order. A `NaiveDateTime` never equals a
  `DateTime`, as in an index lookup.
  """
  def compare(%NaiveDateTime{} = a, %NaiveDateTime{} = b), do: NaiveDateTime.compare(a, b)
  def compare(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)
  def compare(%Date{} = a, %Date{} = b), do: Date.compare(a, b)
  def compare(%Time{} = a, %Time{} = b), do: Time.compare(a, b)

  def compare(a, b) when is_struct(a, Decimal) or is_struct(b, Decimal) do
    with %Decimal{} = da <- to_decimal(a),
         %Decimal{} = db <- to_decimal(b) do
      Decimal.compare(da, db)
    else
      nil -> term_compare(a, b)
    end
  end

  def compare(a, b), do: term_compare(a, b)

  defp term_compare(a, b) when a == b, do: :eq
  defp term_compare(a, b) when a < b, do: :lt
  defp term_compare(_a, _b), do: :gt

  # nil when the value has no ordered Decimal counterpart (NaN, or not a
  # number), which Decimal.compare would raise on.
  defp to_decimal(%Decimal{coef: :NaN}), do: nil
  defp to_decimal(%Decimal{} = d), do: d
  defp to_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp to_decimal(n) when is_float(n), do: Decimal.from_float(n)
  defp to_decimal(_), do: nil

  @doc """
  The value to push to the adapter for an index lookup. efsql queries
  schemaless, so the adapter can't encode a param by its field's Ecto type;
  encode dates and times here exactly as the adapter's default indexer
  does when it writes the index.
  """
  def index_key(%NaiveDateTime{} = x),
    do: x |> NaiveDateTime.add(0, :microsecond) |> NaiveDateTime.to_iso8601(:basic)

  def index_key(%DateTime{} = x),
    do: x |> DateTime.add(0, :microsecond) |> DateTime.to_iso8601(:basic)

  def index_key(%Date{} = x), do: Date.to_iso8601(x, :basic)

  def index_key(%Time{} = x),
    do: x |> Time.add(0, :microsecond) |> Time.to_iso8601(:basic)

  def index_key(x), do: x
end
