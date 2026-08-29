defmodule Efsql.ParserTest do
  use ExUnit.Case, async: true

  alias Efsql.Logical
  alias Efsql.Parser

  defp parse(sql) do
    {:ok, context, tokens} = SQL.Lexer.lex(sql)
    {:ok, _context, parsed} = SQL.Parser.parse(tokens, context)
    Parser.to_logical(parsed)
  end

  describe "select" do
    test "single field" do
      assert %Logical.Select{projection: [:id]} = parse("select id from t.users;")
    end

    test "several fields" do
      assert %Logical.Select{projection: [:id, :name, :notes]} =
               parse("select id, name, notes from t.users;")
    end

    test "double-quoted field" do
      assert %Logical.Select{projection: [:id]} = parse(~s(select "id" from t.users;))
    end

    test "star" do
      assert %Logical.Select{projection: :star} = parse("select * from t.users;")
    end
  end

  describe "from" do
    test "bare table" do
      assert %Logical.Select{source: "users", prefix: nil} = parse("select id from users;")
    end

    test "tenant-qualified table" do
      assert %Logical.Select{source: "users", prefix: "myschema"} =
               parse("select id from myschema.users;")
    end

    test "double-quoted tenant" do
      assert %Logical.Select{source: "users", prefix: "myschema"} =
               parse(~s(select id from "myschema".users;))
    end

    test "storage- and tenant-qualified table" do
      assert %Logical.Select{source: "users", prefix: {"storage", "ten"}} =
               parse("select id from storage.ten.users;")
    end
  end

  describe "where" do
    test "equality" do
      assert %Logical.Select{predicates: [{:cmp, :==, :name, "Alice"}]} =
               parse("select id from t.users where name = 'Alice';")
    end

    test "primary key placeholder" do
      assert %Logical.Select{predicates: [{:cmp, :==, :_, "0001"}]} =
               parse("select id from t.users where _ = '0001';")
    end

    test "comparisons" do
      assert %Logical.Select{predicates: [{:cmp, :>, :_, "0"}]} =
               parse("select id from t.users where _ > '0';")

      assert %Logical.Select{predicates: [{:cmp, :<=, :name, "M"}]} =
               parse("select id from t.users where name <= 'M';")
    end

    test "between" do
      assert %Logical.Select{predicates: [{:range, :name, {:>=, "A"}, {:<=, "C"}}]} =
               parse("select id from t.users where name between 'A' and 'C';")
    end

    test "and-ed conditions flatten in order" do
      assert %Logical.Select{
               predicates: [
                 {:cmp, :==, :a, "x"},
                 {:cmp, :==, :b, "y"},
                 {:cmp, :>, :c, "z"}
               ]
             } = parse("select id from t.users where a = 'x' and b = 'y' and c > 'z';")
    end

    test "like and not like" do
      assert %Logical.Select{predicates: [{:like, :name, "Al%"}]} =
               parse("select id from t.users where name like 'Al%';")

      assert %Logical.Select{predicates: [{:not_like, :name, "Al%"}]} =
               parse("select id from t.users where name not like 'Al%';")
    end

    test "in" do
      assert %Logical.Select{predicates: [{:in, :name, ["a", "b", "c"]}]} =
               parse("select id from t.users where name in ('a', 'b', 'c');")
    end

    test "versionstamp partition scan value" do
      assert %Logical.Select{predicates: [{:cmp, :==, :_, {"p", :*}}]} =
               parse("select id from t.users where _ = ('p', *);")
    end
  end

  describe "order by" do
    test "bare field defaults to asc" do
      assert %Logical.Select{order: [asc: :name]} = parse("select id from t.users order by name;")
    end

    test "explicit directions on multiple fields" do
      assert %Logical.Select{order: [asc: :name, desc: :id]} =
               parse("select id from t.users order by name asc, id desc;")
    end
  end

  describe "limit" do
    test "limit" do
      assert %Logical.Select{limit: 2} = parse("select id from t.users limit 2;")
    end

    test "order by with limit" do
      assert %Logical.Select{order: [asc: :name], limit: 2} =
               parse("select id from t.users order by name limit 2;")
    end
  end
end
