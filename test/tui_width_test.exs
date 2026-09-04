defmodule Efsql.Tui.WidthTest do
  use ExUnit.Case, async: true

  alias Efsql.Render
  alias Efsql.Tui.App
  alias Efsql.Tui.App.Model
  alias Efsql.Tui.View

  @plan %Efsql.Physical.Plan{access: {:pk_range, nil, nil, nil, []}, ops: []}

  defp results(rows, size) do
    {model, _} =
      App.update(
        %Model{
          size: size,
          mode: :query,
          busy: "q",
          tenant: :t,
          tenant_id: "demo",
          storage_id: "s"
        },
        {:done, :query, {:ok, {@plan, rows, %{}, 1}}}
      )

    model
  end

  defp data_lines(model, marker) do
    model
    |> View.view()
    |> elem(0)
    |> Enum.map(&View.strip_ansi/1)
    |> Enum.filter(&String.contains?(&1, marker))
  end

  test "a wide character does not push the columns after it out of line" do
    rows = [
      %{id: "r1", jp: "日本語", tail: "end"},
      %{id: "r2", jp: "ab", tail: "end"}
    ]

    [wide, narrow] = data_lines(results(rows, {24, 100}), "end")

    # both rows pad to the same rendered width, so "end" starts in one column
    assert Render.width(wide) == Render.width(narrow)

    assert String.split(wide, "end") |> hd() |> Render.width() ==
             String.split(narrow, "end") |> hd() |> Render.width()
  end

  test "no frame line is wider than the terminal" do
    rows =
      for i <- 1..5 do
        %{id: "row#{i}", jp: "日本語テキスト", long: String.duplicate("x", 90), n: i}
      end

    for cols <- [40, 60, 80, 100] do
      {lines, _cursor} = View.view(results(rows, {20, cols}))

      for line <- lines do
        assert Render.width(View.strip_ansi(line)) <= cols,
               "line wider than #{cols} columns: #{inspect(View.strip_ansi(line))}"
      end
    end
  end

  test "numeric columns are right-aligned and text columns are not" do
    rows = [%{id: "a", n: 5}, %{id: "b", n: 1234}]

    lines =
      results(rows, {24, 60})
      |> View.view()
      |> elem(0)
      |> Enum.map(&View.strip_ansi/1)
      |> Enum.map(&String.trim_trailing/1)

    row_a = Enum.find(lines, &String.starts_with?(&1, " a "))
    row_b = Enum.find(lines, &String.starts_with?(&1, " b "))

    # 5 is padded on the left so its digit sits under the last digit of 1234
    assert row_a =~ ~r/\s5$/
    assert row_b =~ ~r/\s1234$/
    assert Render.width(row_a) == Render.width(row_b)
  end
end
