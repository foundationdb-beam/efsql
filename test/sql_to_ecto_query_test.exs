defmodule Efsql.SqlToEctoQueryTest do
  use ExUnit.Case, async: true

  alias Efsql.SqlToEctoQuery

  defp parse(sql) do
    {:ok, context, tokens} = SQL.Lexer.lex(sql)
    {:ok, _context, parsed} = SQL.Parser.parse(tokens, context)
    SqlToEctoQuery.to_ecto_query(parsed)
  end

  defmacrop field_ref(atom) do
    quote do
      {{:., [], [{:&, [], [0]}, unquote(atom)]}, [], []}
    end
  end

  # SELECT

  describe "select fields" do
    test "single field" do
      query = parse("select id from t.users;")
      assert %{select: %{take: %{0 => {:any, [:id]}}}} = query
    end

    test "two fields" do
      query = parse("select id, name from t.users;")
      assert %{select: %{take: %{0 => {:any, [:id, :name]}}}} = query
    end

    test "three fields" do
      query = parse("select id, name, notes from t.users;")
      assert %{select: %{take: %{0 => {:any, [:id, :name, :notes]}}}} = query
    end

    test "double-quoted field" do
      query = parse(~s(select "id" from t.users;))
      assert %{select: %{take: %{0 => {:any, [:id]}}}} = query
    end

    test "select * produces nil select" do
      query = parse("select * from t.users;")
      assert %{select: nil} = query
    end
  end

  # FROM

  describe "from clause" do
    test "simple table without schema" do
      query = parse("select id from users;")
      assert %{from: %{source: {"users", nil}}, prefix: nil} = query
    end

    test "schema.table sets source and prefix" do
      query = parse("select id from myschema.users;")
      assert %{from: %{source: {"users", nil}}, prefix: "myschema"} = query
    end

    test "double-quoted schema" do
      query = parse(~s(select id from "myschema".users;))
      assert %{from: %{source: {"users", nil}}, prefix: "myschema"} = query
    end
  end

  # WHERE — equality

  describe "where equality" do
    test "field = value" do
      query = parse("select id from t.users where name = 'Alice';")

      assert [%{op: :and, expr: {:==, [], [field_ref(:name), "Alice"]}}] = query.wheres
    end

    test "primary key _ = value" do
      query = parse("select id from t.users where _ = '0001';")

      assert [%{op: :and, expr: {:==, [], [field_ref(:_), "0001"]}}] = query.wheres
    end
  end

  # WHERE — range operators

  describe "where range" do
    test "field > value" do
      query = parse("select id from t.users where _ > '0';")

      assert [%{op: :and, expr: {:>, [], [field_ref(:_), "0"]}}] = query.wheres
    end

    test "field < value" do
      query = parse("select id from t.users where _ < '0002';")

      assert [%{op: :and, expr: {:<, [], [field_ref(:_), "0002"]}}] = query.wheres
    end

    test "field >= value and field <= value merges into range tuple" do
      query = parse("select id from t.users where _ >= '0001' and _ <= '0002';")

      assert [
               %{
                 op: :and,
                 expr: {
                   {:>=, [], [field_ref(:_), "0001"]},
                   {:<=, [], [field_ref(:_), "0002"]}
                 }
               }
             ] = query.wheres
    end

    test "field > value and field < value merges into range tuple" do
      query = parse("select id from t.users where _ > '0001' and _ < '0003';")

      assert [
               %{
                 op: :and,
                 expr: {
                   {:>, [], [field_ref(:_), "0001"]},
                   {:<, [], [field_ref(:_), "0003"]}
                 }
               }
             ] = query.wheres
    end

    test "field >= value and field <= value on named field" do
      query = parse("select id from t.users where name > 'A' and name < 'C';")

      assert [
               %{
                 op: :and,
                 expr: {
                   {:>, [], [field_ref(:name), "A"]},
                   {:<, [], [field_ref(:name), "C"]}
                 }
               }
             ] = query.wheres
    end
  end

  # WHERE — BETWEEN

  describe "where between" do
    test "field between x and y becomes range tuple" do
      query = parse("select id from t.users where _ between '0001' and '0002';")

      assert [
               %{
                 op: :and,
                 expr: {
                   {:>=, [], [field_ref(:_), "0001"]},
                   {:<=, [], [field_ref(:_), "0002"]}
                 }
               }
             ] = query.wheres
    end

    test "named field between" do
      query = parse("select id from t.users where name between 'A' and 'C';")

      assert [
               %{
                 op: :and,
                 expr: {
                   {:>=, [], [field_ref(:name), "A"]},
                   {:<=, [], [field_ref(:name), "C"]}
                 }
               }
             ] = query.wheres
    end
  end
end
