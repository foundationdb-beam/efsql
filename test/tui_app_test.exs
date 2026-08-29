defmodule Efsql.Tui.AppTest do
  use ExUnit.Case, async: true

  alias Efsql.Discover
  alias Efsql.Tui.App
  alias Efsql.Tui.View

  @size {16, 100}

  defp init() do
    {model, _cmds} = App.init(size: @size, cluster_file: "test.cluster")
    model
  end

  defp feed(model, msgs) do
    Enum.reduce(msgs, {model, []}, fn msg, {model, cmds} ->
      {model, new_cmds} = App.update(model, msg)
      {model, cmds ++ new_cmds}
    end)
  end

  defp frame(model) do
    {lines, _cursor} = View.view(model)
    Enum.map(lines, &View.strip_ansi/1)
  end

  defp frame_text(model), do: model |> frame() |> Enum.join("\n")

  defp chars(string), do: string |> String.graphemes() |> Enum.map(&{:char, &1})

  defp demo_schema() do
    %Discover.Schema{
      source: "users",
      sampled: 3,
      sampled_at: ~U[2026-08-28 12:00:00Z],
      pk: :string,
      indexes: [%{name: :users_name_index, fields: [:name]}],
      fields: [
        %{name: :id, presence: 1.0, types: %{string: 3}, examples: ["0001"]},
        %{name: :name, presence: 1.0, types: %{string: 3}, examples: ["Alice", "Bob"]},
        %{name: :notes, presence: 0.67, types: %{string: 2}, examples: ["Lorem ipsum"]}
      ]
    }
  end

  defp activated() do
    model = init()

    {model, _} =
      feed(model, [
        {:done, :nav_entries, {:ok, ["Ecto.Adapters.FoundationDB", "playground"]}},
        {:key, :enter},
        {:done, :nav_entries, {:ok, ["demo", "staging"]}},
        {:key, :enter},
        {:done, :activate, {:ok, {"Ecto.Adapters.FoundationDB", "demo", :fake_tenant}}},
        {:done, :sources, {:ok, ["orders", "users"]}}
      ])

    model
  end

  test "frames are always exactly the terminal size" do
    for model <- [init(), activated()] do
      lines = frame(model)
      assert length(lines) == 16
      assert Enum.all?(lines, &(String.length(&1) <= 100))
    end
  end

  test "navigator lists, filters, and descends" do
    model = init()
    assert frame_text(model) =~ "loading…"

    {model, _} = feed(model, [{:done, :nav_entries, {:ok, ["Ecto.Adapters.FoundationDB", "playground"]}}])
    text = frame_text(model)
    assert text =~ "Storage ids"
    assert text =~ "Ecto.Adapters.FoundationDB"
    assert text =~ "playground"

    {model, _} = feed(model, chars("play"))
    text = frame_text(model)
    assert text =~ "playground"
    refute text =~ "Ecto.Adapters"

    {_, cmds} = feed(model, [{:key, :enter}])
    assert [{:task, :nav_entries, _}] = cmds
  end

  test "activating a tenant lands in the schema browser" do
    model = activated()
    assert model.mode == :schema

    text = frame_text(model)
    assert text =~ "Sources"
    assert text =~ "users"
    assert text =~ "orders"
    assert text =~ "demo"
  end

  test "schema browser shows sampled fields" do
    model = activated()

    {model, _} =
      feed(model, [
        {:key, :down},
        {:key, :enter},
        {:done, {:schema, "users"}, {:ok, demo_schema()}}
      ])

    text = frame_text(model)
    assert text =~ "sampled 3 rows"
    assert text =~ "users_name_index"
    assert text =~ "name"
    assert text =~ "67%"
    assert text =~ "Lorem ipsum"
  end

  test "enter on a field pre-fills a query" do
    model = activated()

    {model, _} =
      feed(model, [
        {:key, :down},
        {:key, :enter},
        {:done, {:schema, "users"}, {:ok, demo_schema()}},
        {:key, :down},
        {:key, :enter}
      ])

    assert model.mode == :query
    assert model.input == "select name from users limit 15;"
  end

  test "query editing, history, and completion cycling" do
    model = %{activated() | mode: :query, schemas: %{"users" => demo_schema()}}

    {model, _} = feed(model, chars("select id from users where na") ++ [{:key, :tab}])
    assert model.input == "select id from users where name"

    {model, cmds} = feed(model, [{:key, :enter}])
    assert [{:task, :query, _}] = cmds
    assert model.input == ""

    plan = %Efsql.Physical.Plan{access: {:pk_range, nil, nil, nil, []}, ops: []}
    {model, _} = feed(model, [{:done, :query, {:ok, {plan, [], %{}, 1}}}])

    {model, _} = feed(model, [{:key, :up}])
    assert model.input == "select id from users where name;"
  end

  test "query results render, browse, and inspect" do
    model = %{activated() | mode: :query}
    rows = for i <- 1..3, do: %{id: "000#{i}", name: "User #{i}", notes: nil}

    plan = %Efsql.Physical.Plan{access: {:pk_range, nil, nil, nil, []}, ops: []}
    {model, _} = feed(model, [{:done, :query, {:ok, {plan, rows, %{}, 7}}}])

    text = frame_text(model)
    assert text =~ "(3 rows, 7 ms)"
    assert text =~ "User 1"

    # tab into results, move down, inspect the second row
    {model, _} = feed(model, [{:key, :tab}, {:key, :down}, {:key, :enter}])
    assert model.mode == :inspector
    assert model.irow.id == "0002"

    text = frame_text(model)
    assert text =~ "0002"
    assert text =~ "nil"

    {model, _} = feed(model, [{:key, :esc}])
    assert model.mode == :query
  end

  test "errors surface in the bottom bar" do
    model = %{activated() | mode: :query}

    {model, _} =
      feed(model, [{:done, :query, {:error, %Efsql.Exception.Unsupported{message: "'or' is not supported"}}}])

    assert frame_text(model) =~ "'or' is not supported"
  end

  test "ctrl-c cancels a running task before quitting" do
    model = %{init() | busy: "running query"}

    {model, cmds} = feed(model, [{:key, :ctrl_c}])
    assert model.busy == nil
    assert :cancel_tasks in cmds

    {_, cmds} = feed(model, [{:key, :ctrl_c}])
    assert :quit in cmds
  end
end
