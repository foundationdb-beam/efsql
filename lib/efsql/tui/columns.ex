defmodule Efsql.Tui.Columns do
  @moduledoc """
  Result-table column sizing, following the DuckDB CLI's box renderer.

  A column is as wide as its widest value, and nothing is capped while the
  row fits. Only when the row would overflow does sizing kick in, in the two
  stages DuckDB uses:

    1. clamp over-wide columns to `max_col_width`, left to right, stopping at
       the first column whose clamping makes the row fit — that one is
       narrowed only as far as needed, so the rightmost clamped column keeps
       whatever slack is left over;
    2. if it still does not fit, drop columns in zig-zag order outward from
       the middle, replacing all of them with a single `…` column.

  Geometry is a parameter because efsql separates columns with two spaces
  where DuckDB draws `│`-delimited cells. With `lead: 4, gutter: 3` this
  module reproduces DuckDB's widths exactly; the defaults describe efsql's
  own frame. See `test/tui_columns_test.exs`, which pins both.
  """

  @max_col_width 20

  @doc "The width a column is clamped to when the row does not fit."
  def max_col_width, do: @max_col_width

  @doc """
  Sizes columns of `natural` width to fit within `budget` terminal columns.

  Returns `{widths, column_map}`. `column_map` has one entry per rendered
  column, either `{:col, index}` into the caller's column list or `:split`
  for the `…` that stands in for every dropped column. `widths` lines up with
  it one for one.

  Options mirror the frame geometry: `:lead` is the fixed cost of a row
  before any column, `:gutter` the cost of the separator between two, and
  `:split_width` the width of the `…` column.
  """
  def layout(natural, budget, opts \\ [])

  def layout([], _budget, _opts), do: {[], []}

  def layout(natural, budget, opts) do
    geom = %{
      lead: Keyword.get(opts, :lead, 1),
      gutter: Keyword.get(opts, :gutter, 2),
      split_width: Keyword.get(opts, :split_width, 1)
    }

    total = total_width(natural, geom)

    {widths, total} =
      if total > budget, do: clamp(natural, total, budget, geom), else: {natural, total}

    if total > budget do
      prune(widths, total, budget, geom)
    else
      {widths, Enum.map(0..(length(widths) - 1), &{:col, &1})}
    end
  end

  defp total_width(widths, geom) do
    geom.lead + Enum.sum(widths) + geom.gutter * max(length(widths) - 1, 0)
  end

  # -- stage 1: clamp over-wide columns, left to right --

  defp clamp(widths, total, budget, geom), do: clamp(widths, [], total, budget, geom)

  defp clamp([], acc, total, _budget, _geom), do: {Enum.reverse(acc), total}

  defp clamp([w | rest], acc, total, budget, geom) when w > @max_col_width do
    max_diff = w - @max_col_width

    if total - max_diff <= budget do
      # clamping this column is enough, so take only the slack we need
      {Enum.reverse(acc) ++ [w - (total - budget) | rest], budget}
    else
      clamp(rest, [@max_col_width | acc], total - max_diff, budget, geom)
    end
  end

  defp clamp([w | rest], acc, total, budget, geom),
    do: clamp(rest, [w | acc], total, budget, geom)

  # -- stage 2: drop columns outward from the middle --

  defp prune(widths, total, budget, geom) do
    count = length(widths)
    # the `…` column replacing them costs its own width plus a separator
    total = total + geom.split_width + geom.gutter
    dropped = select(widths, count, total, budget, 0, MapSet.new(), geom)

    {kept, map} =
      Enum.reduce(0..(count - 1), {[], []}, fn c, {kept, map} ->
        cond do
          not MapSet.member?(dropped, c) -> {[Enum.at(widths, c) | kept], [{:col, c} | map]}
          # every dropped column collapses into one `…`
          :split in map -> {kept, map}
          true -> {[geom.split_width | kept], [:split | map]}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(map)}
  end

  # DuckDB's zig-zag: the middle column first, then alternating outward
  # (offset 0, -1, 1, -2, 2, ...), so the first and last columns survive
  # longest — those are the ones you steer by.
  defp select(widths, count, total, budget, offset, dropped, geom) do
    cond do
      total <= budget ->
        dropped

      # never drop everything: one column always stays
      MapSet.size(dropped) >= count - 1 ->
        dropped

      abs(offset) > count ->
        dropped

      true ->
        c = div(count, 2) + offset
        next = if offset >= 0, do: -offset - 1, else: -offset

        if c < 0 or c >= count or MapSet.member?(dropped, c) do
          select(widths, count, total, budget, next, dropped, geom)
        else
          total = total - (Enum.at(widths, c) + geom.gutter)
          select(widths, count, total, budget, next, MapSet.put(dropped, c), geom)
        end
    end
  end
end
