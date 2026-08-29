defmodule Efsql.Render do
  @moduledoc """
  Friendly, Elixir-style rendering of values pulled from FoundationDB.
  `cell/2` renders a value for a table cell (single line, truncated);
  `full/2` renders a value for the Inspector (multi-line, complete).
  """

  def cell(value, width \\ 40) do
    value
    |> render(width, false)
    |> truncate(width)
  end

  def full(value, width \\ 80) do
    render(value, width, true)
  end

  defp render(nil, _width, _multi), do: "nil"

  defp render(v, _width, _multi) when is_binary(v) do
    if String.valid?(v) and String.printable?(v) do
      v
    else
      hex = v |> binary_part(0, min(byte_size(v), 8)) |> Base.encode16(case: :lower)
      "<<0x#{hex}#{if byte_size(v) > 8, do: "…"}>> (#{byte_size(v)} bytes)"
    end
  end

  defp render({:versionstamp, _, _, _} = v, _width, _multi) do
    "#Versionstamp<#{EctoFoundationDB.Versionstamp.to_integer(v)}>"
  end

  defp render(v, width, multi) do
    inspect(v,
      pretty: multi,
      width: width,
      limit: if(multi, do: :infinity, else: 10),
      printable_limit: if(multi, do: :infinity, else: 64),
      syntax_colors: []
    )
  end

  def truncate(string, width) do
    if String.length(string) > width do
      String.slice(string, 0, max(width - 1, 0)) <> "…"
    else
      string
    end
  end

  @doc "Short name for a value's type, for schema discovery displays."
  def type_of(nil), do: :null
  def type_of(v) when is_boolean(v), do: :boolean
  def type_of(v) when is_integer(v), do: :integer
  def type_of(v) when is_float(v), do: :float
  def type_of({:versionstamp, _, _, _}), do: :versionstamp
  def type_of(%DateTime{}), do: :utc_datetime
  def type_of(%NaiveDateTime{}), do: :naive_datetime
  def type_of(%Date{}), do: :date
  def type_of(%Time{}), do: :time
  def type_of(%Decimal{}), do: :decimal
  def type_of(v) when is_map(v), do: :map
  def type_of(v) when is_list(v), do: :list

  def type_of(v) when is_binary(v) do
    if String.valid?(v) and String.printable?(v), do: :string, else: :binary
  end

  def type_of(_), do: :term
end
