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

  test "uuid primary keys are not truncated in results" do
    model = %{activated() | mode: :query}
    uuid = "00ab2aa8-2bba-4102-bf8c-ced5d3142f8a"
    rows = [%{id: uuid, item: "widget"}]

    plan = %Efsql.Physical.Plan{access: {:pk_range, nil, nil, nil, []}, ops: []}
    {model, _} = feed(model, [{:done, :query, {:ok, {plan, rows, %{}, 1}}}])

    text = frame_text(model)
    assert text =~ uuid
    refute text =~ "ced5d3142f8…"
  end

  test "a long single-line string wraps in the inspector instead of truncating" do
    model = %{activated() | mode: :query}
    long = String.duplicate("abcdefghij", 30)
    rows = [%{id: "0001", blob: long}]

    plan = %Efsql.Physical.Plan{access: {:pk_range, nil, nil, nil, []}, ops: []}
    {model, _} = feed(model, [{:done, :query, {:ok, {plan, rows, %{}, 1}}}])
    {model, _} = feed(model, [{:key, :tab}, {:key, :enter}])
    assert model.mode == :inspector

    lines = frame(model)
    # every frame line still fits the terminal
    assert Enum.all?(lines, &(String.length(&1) <= 100))

    # the value pane shows several wrapped lines, not one ellipsised line
    body = Enum.drop_while(lines, &(not String.contains?(&1, "blob"))) |> Enum.drop(1)
    wrapped = Enum.filter(body, &String.contains?(&1, "abcdefghij"))
    assert length(wrapped) > 1
    refute Enum.any?(wrapped, &String.contains?(&1, "…"))
  end

  describe "inspector value scrolling" do
    defp inspector_with_long_value() do
      model = %{activated() | mode: :query}
      # 60 numbered lines, so we can tell which part of the value is on screen
      long = Enum.map_join(1..60, "\n", &"line#{&1}")
      plan = %Efsql.Physical.Plan{access: {:pk_range, nil, nil, nil, []}, ops: []}

      {model, _} = feed(model, [{:done, :query, {:ok, {plan, [%{id: "0001", blob: long}], %{}, 1}}}])
      {model, _} = feed(model, [{:key, :tab}, {:key, :enter}])
      model
    end

    test "starts at the top and reports its position" do
      model = inspector_with_long_value()
      text = frame_text(model)

      assert model.ivalue_scroll == 0
      assert text =~ "line1"
      assert text =~ "of 60"
      refute text =~ "line60"
    end

    test "page down reveals later lines" do
      {model, _} = feed(inspector_with_long_value(), [{:key, :page_down}])
      text = frame_text(model)

      assert model.ivalue_scroll == 10
      assert text =~ "lines 11-"
      assert text =~ "line11"
      # the first page is no longer in the value pane
      refute Enum.any?(frame(model), &(String.trim(&1) == "line1"))
    end

    test "page up clamps at the top" do
      {model, _} = feed(inspector_with_long_value(), [{:key, :page_up}, {:key, :page_up}])
      assert model.ivalue_scroll == 0
      assert frame_text(model) =~ "line1"
    end

    test "scrolling past the end still renders a full frame" do
      {model, _} = feed(inspector_with_long_value(), List.duplicate({:key, :page_down}, 20))
      lines = frame(model)

      assert length(lines) == 16
      assert Enum.all?(lines, &(String.length(&1) <= 100))
      # the view clamps to the last page rather than showing blank space
      assert frame_text(model) =~ "line60"
    end

    test "changing field resets the scroll" do
      {model, _} = feed(inspector_with_long_value(), [{:key, :page_down}])
      assert model.ivalue_scroll == 10

      {model, _} = feed(model, [{:key, :down}])
      assert model.ivalue_scroll == 0
    end

    test "a value that fits shows no scroll indicator" do
      model = %{activated() | mode: :query}
      plan = %Efsql.Physical.Plan{access: {:pk_range, nil, nil, nil, []}, ops: []}
      {model, _} = feed(model, [{:done, :query, {:ok, {plan, [%{id: "0001"}], %{}, 1}}}])
      {model, _} = feed(model, [{:key, :tab}, {:key, :enter}])

      # the position indicator only appears when the value overflows
      refute frame_text(model) =~ "lines 1-"
    end
  end

  test "errors surface in the bottom bar" do
    model = %{activated() | mode: :query}

    {model, _} =
      feed(model, [{:done, :query, {:error, %Efsql.Exception.Unsupported{message: "'or' is not supported"}}}])

    assert frame_text(model) =~ "'or' is not supported"
  end

  test "? opens help from browsing modes and returns where it came from" do
    model = activated()

    {help, _} = feed(model, [{:char, "?"}])
    assert help.mode == :help
    assert help.help_return == :schema

    text = frame_text(help)
    # the constructions that have no standard SQL equivalent
    assert text =~ "primary key"
    assert text =~ "_ = 'u0001'"

    {back, _} = feed(help, [{:key, :esc}])
    assert back.mode == :schema
  end

  test "\\? opens help from the query editor and returns to it" do
    model = %{activated() | mode: :query}

    {help, _} = feed(model, chars("\\?") ++ [{:key, :enter}])
    assert help.mode == :help
    assert help.help_return == :query
    assert help.input == ""

    {back, _} = feed(help, [{:key, :esc}])
    assert back.mode == :query
  end

  test "? is a plain character in the query editor" do
    model = %{activated() | mode: :query}

    {typed, _} = feed(model, chars("where name like 'a?'"))
    assert typed.mode == :query
    assert typed.input == "where name like 'a?'"
  end

  test "help scrolls and clamps, and documents versionstamp partitions" do
    model = activated()
    {help, _} = feed(model, [{:char, "?"}])

    # scrolling up at the top stays put
    {up, _} = feed(help, [{:key, :up}, {:key, :up}])
    assert up.help_scroll == 0

    {down, _} = feed(help, [{:key, :page_down}])
    assert down.help_scroll == 10
    assert length(frame(down)) == 16

    # the whole page is reachable by scrolling
    all = for s <- 0..40, do: frame_text(%{help | help_scroll: s})
    assert Enum.any?(all, &(&1 =~ "('u0006', *)"))
    assert Enum.any?(all, &(&1 =~ "or is not supported"))
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
