defmodule Efsql.SessionTest do
  use ExUnit.Case, async: true

  alias Efsql.Exception.Unsupported
  alias Efsql.Physical.Plan
  alias Efsql.Result
  alias Efsql.Session

  test "a table without a tenant needs an active one" do
    assert_raise Unsupported, ~r/no active tenant/, fn ->
      Session.run(%Session{}, "select id from users;")
    end
  end

  test "a result knows its columns and how many transactions it took" do
    rows = [%{id: 1, name: "a"}]

    assert %Result{rows: ^rows, columns: [:name, :id], transactions: 1, elapsed_ms: 5} =
             Result.new(%Plan{access: {:fan_out, []}, columns: [:name, :id]}, rows, 5)

    batches = {:batches, [{:fan_out, []}, {:fan_out, []}, {:fan_out, []}], 2}

    assert %Result{columns: [:id, :name], transactions: 3} =
             Result.new(%Plan{access: batches}, rows)
  end
end
