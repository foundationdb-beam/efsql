defmodule Efsql.CompleteTest do
  use ExUnit.Case, async: true

  alias Efsql.Complete

  @context %{
    tables: ["users", "orders"],
    fields: %{"users" => ["id", "name", "notes"], "orders" => ["id", "item", "qty"]}
  }

  test "statement start" do
    assert {0, ["select"]} = Complete.complete("", @context)
    assert {0, ["select"]} = Complete.complete("sel", @context)
  end

  test "select list offers fields and star" do
    {7, candidates} = Complete.complete("select ", @context)
    assert "*" in candidates
    assert "name" in candidates
    assert "item" in candidates
  end

  test "predicate fields narrow to the from table when known" do
    {_, candidates} = Complete.complete("select id from users where na", @context)
    assert candidates == ["name"]

    {_, candidates} = Complete.complete("select id from orders where na", @context)
    assert candidates == []
  end

  test "from offers tables" do
    assert {15, ["users"]} = Complete.complete("select id from u", @context)
  end

  test "where offers the table's fields" do
    {_, candidates} = Complete.complete("select id from orders where ", @context)
    assert Enum.sort(candidates) == ["id", "item", "qty"]
  end

  test "after a predicate field offers operators" do
    {_, candidates} = Complete.complete("select id from users where name ", @context)
    assert "like" in candidates
    assert "between" in candidates
  end

  test "is offers null and not null" do
    {_, candidates} = Complete.complete("select id from users where name ", @context)
    assert "is" in candidates

    assert {_, ["null", "not"]} =
             Complete.complete("select id from users where name is ", @context)

    assert {_, ["null"]} =
             Complete.complete("select id from users where name is not ", @context)

    {_, candidates} = Complete.complete("select id from users where name is null ", @context)
    assert "and" in candidates
    assert "or" in candidates
  end

  test "order by offers fields" do
    assert {_, ["by"]} = Complete.complete("select id from users order ", @context)
    assert {_, ["by"]} = Complete.complete("select id from users group ", @context)

    {_, candidates} = Complete.complete("select id from users group by ", @context)
    assert "name" in candidates

    assert {_, ["order", "limit"]} =
             Complete.complete("select name from users group by name ", @context)

    {_, candidates} = Complete.complete("select id from users ", @context)
    assert "group" in candidates
    {_, candidates} = Complete.complete("select id from users order by ", @context)
    assert "name" in candidates
  end

  test "prefix filtering is case-insensitive" do
    {_, candidates} = Complete.complete("select id from users where NA", @context)
    assert candidates == ["name"]
  end
end
