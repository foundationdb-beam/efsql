defmodule Efsql.PlannerSplitTest do
  use ExUnit.Case, async: true

  alias Efsql.Predicate
  alias Efsql.Logical
  alias Efsql.Planner

  defp split(sql), do: sql |> Efsql.Parser.sql_to_logical() |> Planner.split()

  test "select *: read everything, order and limit afterwards" do
    assert {%Logical.Select{projection: :star, order: [], limit: nil}, ops} =
             split("select * from *.users order by name desc limit 5;")

    assert ops == [{:sort, [desc: :name]}, {:limit, 5}]
  end

  test "fields to order by are read too, then projected away" do
    assert {%Logical.Select{projection: [:id, :name]}, ops} =
             split("select id from *.users order by name;")

    assert ops == [{:sort, [asc: :name]}, {:project, [:id]}]
  end

  test "a read never asks for _tenant" do
    assert {%Logical.Select{projection: [:id]}, []} =
             split("select _tenant, id from *.users;")

    assert {%Logical.Select{projection: :star}, []} = split("select _tenant from *.users;")
  end

  test "a grouped query reads its group and aggregate fields, then aggregates" do
    assert {%Logical.Select{projection: [:name], group_by: nil, aggregates: []}, ops} =
             split("select _tenant, count(name) as n from *.users group by _tenant order by n;")

    assert ops == [
             {:aggregate, [:_tenant], [{:n, :count, :name}]},
             {:sort, [asc: :n]}
           ]
  end

  test "predicates stay with the read" do
    assert {%Logical.Select{predicates: [{:cmp, :==, :name, "Alice"}]}, _ops} =
             split("select id from *.users where name = 'Alice';")
  end

  test "tenant names are chosen with the usual predicate semantics" do
    preds = [{:like, :_tenant, "acme%"}]
    assert Predicate.matches?(%{_tenant: "acme-eu"}, preds)
    refute Predicate.matches?(%{_tenant: "globex"}, preds)
    assert Predicate.matches?(%{_tenant: "anything"}, [])
  end
end
