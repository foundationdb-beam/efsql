defmodule Efsql.Tui.View do
  @moduledoc """
  Pure rendering: `view(model) -> {lines, cursor}`. `lines` has exactly
  `rows` entries, each an ANSI-styled binary no wider than `cols`;
  `cursor` is `nil` or a 1-based `{row, col}` where the terminal cursor is
  shown (the query input).

  Lines are composed from `{style, text}` segments; truncation happens on
  the plain text, so ANSI codes never get cut in half.
  """

  alias Efsql.Discover
  alias Efsql.Render
  alias Efsql.Tui.App
  alias Efsql.Tui.App.Model

  @styles %{
    none: "",
    inv: "\e[7m",
    sel: "\e[7m",
    dim: "\e[90m",
    accent: "\e[36m",
    err: "\e[31m",
    ok: "\e[32m",
    head: "\e[1m"
  }
  @reset "\e[0m"

  def view(%Model{size: {rows, cols}} = model) do
    content_height = max(rows - 2, 1)
    {content, cursor} = content(model, content_height, cols)

    lines =
      [title_bar(model, cols)] ++
        fit(content, content_height, cols) ++
        [bottom_bar(model, cols)]

    cursor =
      case cursor do
        nil -> nil
        {r, c} -> {r + 1, min(c, cols)}
      end

    {Enum.map(lines, &render_line(&1, cols)), cursor}
  end

  defp fit(lines, height, _cols) do
    lines
    |> Enum.take(height)
    |> pad_list(height)
  end

  defp pad_list(lines, height), do: lines ++ List.duplicate([], height - length(lines))

  # -- chrome --

  defp title_bar(model, _cols) do
    session =
      case model.tenant_id do
        nil -> "no tenant"
        tenant_id -> "#{model.storage_id} / #{tenant_id}"
      end

    [{:inv, " efsql · #{model.mode} "}, {:none, "  "}, {:accent, session}, {:dim, "  #{model.cluster_file}"}]
  end

  defp bottom_bar(%Model{flash: {:error, msg}}, _cols), do: [{:err, " " <> msg}]
  defp bottom_bar(%Model{flash: {:info, msg}}, _cols), do: [{:ok, " " <> msg}]
  defp bottom_bar(%Model{busy: busy}, _cols) when busy != nil, do: [{:accent, " ⋯ #{busy} (Esc cancels)"}]

  defp bottom_bar(%Model{mode: mode, qfocus: qfocus} = model, _cols) do
    hints =
      case {mode, qfocus} do
        {:navigator, _} -> "↑↓ move · type to filter · Enter open · ? help · ^D quit"
        {:schema, _} -> "↑↓ move · Enter open · q query · t tenants · r resample · ? help"
        {:query, :input} -> "Enter run · Tab complete · ↑↓ history · Esc schema · \\? help · \\plan"
        {:query, :results} -> "↑↓ move · Enter inspect · Tab/Esc back to input"
        {:inspector, _} -> inspector_hint(model)
        {:help, _} -> "↑↓ scroll · Esc back"
      end

    [{:dim, " " <> hints}]
  end

  defp inspector_hint(%Model{ifocus: :value}),
    do: "↑↓ scroll · Space/b page · g/G top/bottom · Tab fields · Esc back"

  defp inspector_hint(%Model{ifocus: :fields}),
    do: "↑↓ field · Tab scroll value · Space/b page · Esc back · ? help"

  # -- content per mode --

  defp content(%Model{mode: :navigator} = model, height, cols), do: {navigator(model, height, cols), nil}
  defp content(%Model{mode: :schema} = model, height, cols), do: {schema(model, height, cols), nil}
  defp content(%Model{mode: :query} = model, height, cols), do: query(model, height, cols)
  defp content(%Model{mode: :inspector} = model, height, cols), do: {inspector(model, height, cols), nil}
  defp content(%Model{mode: :help} = model, height, _cols), do: {help(model, height), nil}

  # -- help --

  defp help(%Model{help_scroll: scroll}, height) do
    lines = Efsql.Tui.Help.lines()
    max_scroll = max(length(lines) - height, 0)
    scroll = min(scroll, max_scroll)
    shown = Enum.slice(lines, scroll, height)

    if scroll < max_scroll do
      Enum.take(shown, height - 1) ++ [[{:dim, " ↓ more"}]]
    else
      shown
    end
  end

  # -- navigator --

  defp navigator(model, height, _cols) do
    heading =
      case model.nav_path do
        [] -> [{:head, " Storage ids"}, {:dim, "  (FDB directory root)"}]
        [sid] -> [{:head, " Tenants"}, {:dim, "  in #{sid}"}]
      end

    filter =
      if model.nav_filter == "",
        do: [{:dim, " filter: (type to filter)"}],
        else: [{:none, " filter: "}, {:accent, model.nav_filter}]

    entries =
      case model.nav_entries do
        nil ->
          [[{:dim, " loading…"}]]

        _ ->
          case App.nav_visible(model) do
            [] -> [[{:dim, " (empty)"}]]
            visible -> list_lines(visible, model.nav_cursor, height - 3, & &1)
          end
      end

    [heading, filter, []] ++ entries
  end

  # -- schema browser --

  defp schema(%Model{sources: nil}, _height, _cols), do: [[{:dim, " loading sources…"}]]

  defp schema(model, height, cols) do
    left_w = 24
    source = App.current_source(model)

    left =
      [[{:head, " Sources"}]] ++
        case model.sources do
          [] -> [[{:dim, " (none)"}]]
          sources -> list_lines(sources, model.src_cursor, height - 1, & &1, model.focus == :sources)
        end

    right = schema_fields(model, source, height, cols - left_w - 1)

    merge_panes(left, right, left_w, height)
  end

  defp schema_fields(_model, nil, _height, _width), do: []

  defp schema_fields(model, source, height, width) do
    case model.schemas[source] do
      nil ->
        [[{:head, " #{source}"}], [{:dim, " Enter to sample this source"}]]

      %Discover.Schema{} = schema ->
        info =
          " sampled #{schema.sampled} rows at #{Calendar.strftime(schema.sampled_at, "%H:%M:%S")}" <>
            " · pk: #{schema.pk || "?"} · r resamples"

        indexes =
          case schema.indexes do
            [] -> " indexes: (none)"
            idxs -> " indexes: " <> Enum.map_join(idxs, ", ", &"#{&1.name}#{inspect(&1.fields)}")
          end

        header = [{:head, pad(" field", 15) <> pad("pres", 6) <> pad("types", 15) <> "examples"}]

        rows =
          schema.fields
          |> list_lines(model.field_cursor, height - 5, &field_line(&1, width), model.focus == :fields)

        [[{:head, " #{source}"}], [{:dim, info}], [{:dim, indexes}], header] ++ rows
    end
  end

  defp field_line(field, width) do
    types =
      field.types
      |> Enum.sort_by(fn {_t, n} -> -n end)
      |> Enum.map_join(",", fn {t, _n} -> t end)

    examples = Enum.map_join(field.examples, " · ", &Render.cell(&1, 24))
    pres = trunc(field.presence * 100)

    Render.truncate(
      pad(" #{field.name}", 15) <> pad("#{pres}%", 6) <> pad(types, 15) <> examples,
      max(width, 20)
    )
  end

  # -- query --

  defp query(model, height, cols) do
    prompt = "sql> "
    input_line = [{:accent, prompt}, {:none, model.input}]

    cursor =
      if model.qfocus == :input,
        do: {1, String.length(prompt) + model.qcursor + 1},
        else: nil

    completion =
      case model.completion do
        {_start, candidates, ix, _tail} when length(candidates) > 1 ->
          [
            Enum.with_index(candidates)
            |> Enum.take(8)
            |> Enum.flat_map(fn {c, i} ->
              [{if(i == ix, do: :sel, else: :dim), " #{c} "}]
            end)
          ]

        _ ->
          []
      end

    plan_lines =
      if model.show_plan? and model.plan do
        [[{:dim, Render.truncate(" plan: " <> inspect(model.plan.access, width: :infinity), cols)}]] ++
          [[{:dim, Render.truncate(" ops:  " <> inspect(model.plan.ops, width: :infinity), cols)}]]
      else
        []
      end

    used = 1 + length(completion) + length(plan_lines)
    results = results_lines(model, height - used - 1, cols)

    {[input_line] ++ completion ++ plan_lines ++ [[]] ++ results, cursor}
  end

  defp results_lines(%Model{rows: nil}, _height, _cols) do
    [[{:dim, " no results yet — run a statement, or Esc for the schema browser"}]]
  end

  defp results_lines(%Model{rows: []} = model, _height, _cols) do
    [[{:dim, " (0 rows, #{model.elapsed_ms} ms)"}]]
  end

  defp results_lines(model, height, cols) do
    # shrink from the right if the row would overflow the screen
    widths = shrink(model.col_widths, cols - 2)
    visible = max(height - 2, 1)
    count = length(model.rows)
    start = if model.row_cursor >= visible, do: model.row_cursor - visible + 1, else: 0

    header = [{:head, row_text(Enum.map(model.columns, &to_string/1), widths)}]

    rows =
      model.cells
      |> Enum.slice(start, visible)
      |> Enum.with_index(start)
      |> Enum.map(fn {cells, ix} ->
        style = if model.qfocus == :results and ix == model.row_cursor, do: :sel, else: :none
        [{style, row_text(cells, widths)}]
      end)

    footer =
      [
        {:dim,
         " (#{count} rows, #{model.elapsed_ms} ms)" <>
           if(model.qfocus == :input and count > 0, do: " — Tab with empty input to browse rows", else: "")}
      ]

    [header] ++ rows ++ [footer]
  end

  defp shrink(widths, budget) do
    total = Enum.sum(widths) + 2 * length(widths)

    if total <= budget or length(widths) <= 1 do
      widths
    else
      widths |> Enum.reverse() |> tl() |> Enum.reverse() |> shrink(budget)
    end
  end

  defp row_text(cells, widths) do
    cells
    |> Enum.zip(widths)
    |> Enum.map_join("  ", fn {cell, w} -> pad(Render.truncate(cell, w), w) end)
    |> then(&(" " <> &1))
  end

  # -- inspector --

  defp inspector(%Model{irow: row} = model, height, cols) do
    fields = row |> Map.keys() |> Enum.sort()
    selected = Enum.at(fields, model.ifield_cursor)

    list =
      fields
      |> list_lines(
        model.ifield_cursor,
        min(length(fields), div(height, 2)),
        fn f -> pad(" #{f}", 20) <> Render.cell(Map.get(row, f), cols - 24) end,
        model.ifocus == :fields
      )

    # App owns this layout math so its scroll clamping cannot drift from ours.
    {lines, value_height} = App.inspector_value(model)
    max_scroll = max(length(lines) - value_height, 0)
    scroll = min(model.ivalue_scroll, max_scroll)

    value =
      lines
      |> Enum.slice(scroll, value_height)
      |> Enum.map(&[{:none, "  " <> &1}])

    marker = if model.ifocus == :value, do: "▸ ", else: "  "

    header =
      if max_scroll > 0 do
        shown_to = min(scroll + value_height, length(lines))

        [
          {:head, " #{marker}#{selected}"},
          {:dim, "  lines #{scroll + 1}-#{shown_to} of #{length(lines)}"}
        ]
      else
        [{:head, " #{marker}#{selected}"}]
      end

    [[{:head, " Row"}]] ++ list ++ [[], header] ++ value
  end

  # -- helpers --

  defp list_lines(items, cursor, visible, text_fun, focused? \\ true) do
    visible = max(visible, 1)
    start = if cursor >= visible, do: cursor - visible + 1, else: 0

    items
    |> Enum.slice(start, visible)
    |> Enum.with_index(start)
    |> Enum.map(fn {item, ix} ->
      style = if ix == cursor and focused?, do: :sel, else: :none
      marker = if ix == cursor, do: ">", else: " "
      [{style, " #{marker} #{text_fun.(item)}"}]
    end)
  end

  defp merge_panes(left, right, left_w, height) do
    left = pad_list(Enum.take(left, height), height)
    right = pad_list(Enum.take(right, height), height)

    Enum.zip(left, right)
    |> Enum.map(fn {l_segs, r_segs} ->
      l_text = plain(l_segs)

      restyled =
        case l_segs do
          [{style, _} | _] -> [{style, pad(Render.truncate(l_text, left_w), left_w)}]
          [] -> [{:none, pad("", left_w)}]
        end

      restyled ++ [{:dim, "│"}] ++ r_segs
    end)
  end

  defp plain(segments), do: Enum.map_join(segments, "", fn {_s, t} -> t end)

  defp pad(text, width) do
    text
    |> Render.truncate(width)
    |> String.pad_trailing(width)
  end

  @doc "Renders one line of `{style, text}` segments to an ANSI binary within `cols`."
  def render_line(segments, cols) do
    {iodata, _remaining} =
      Enum.reduce(segments, {[], cols}, fn {style, text}, {acc, remaining} ->
        text = Render.truncate(text, remaining)
        used = String.length(text)

        styled =
          case Map.fetch!(@styles, style) do
            "" -> text
            code -> code <> text <> @reset
          end

        {[acc, styled], remaining - used}
      end)

    IO.iodata_to_binary(iodata)
  end

  @doc "The plain text of a rendered frame line, for tests."
  def strip_ansi(line), do: String.replace(line, ~r/\e\[[0-9;?]*[A-Za-z]/, "")
end
