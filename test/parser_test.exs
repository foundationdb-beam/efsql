defmodule Efsql.ParserTest do
  use ExUnit.Case, async: true

  alias Efsql.Exception.Unsupported
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

    test "numeric and boolean literals" do
      assert %Logical.Select{predicates: [{:cmp, :>, :age, 40}]} =
               parse("select id from t.users where age > 40;")

      assert %Logical.Select{predicates: [{:cmp, :>, :score, 1.5}]} =
               parse("select id from t.users where score > 1.5;")

      assert %Logical.Select{predicates: [{:cmp, :==, :active, true}]} =
               parse("select id from t.users where active = true;")

      assert %Logical.Select{predicates: [{:range, :age, {:>=, 30}, {:<=, 40}}]} =
               parse("select id from t.users where age between 30 and 40;")

      assert %Logical.Select{predicates: [{:in, :qty, [1, 2, 3]}]} =
               parse("select id from t.users where qty in (1, 2, 3);")
    end

    test "atom literal" do
      assert %Logical.Select{predicates: [{:cmp, :==, :status, :active}]} =
               parse("select id from t.users where status = 'active'::atom;")

      assert %Logical.Select{predicates: [{:cmp, :==, :status, :active}]} =
               parse("select id from t.users where status = cast('active' as atom);")

      assert %Logical.Select{predicates: [{:cmp, :==, :status, :active}]} =
               parse("select id from t.users where status = 'active'::ATOM;")
    end

    test "atom literal is distinct from a string" do
      assert %Logical.Select{predicates: [{:cmp, :==, :status, "active"}]} =
               parse("select id from t.users where status = 'active';")
    end

    test "atom literal keeps case and module names" do
      assert %Logical.Select{predicates: [{:cmp, :==, :kind, Foo.Bar}]} =
               parse("select id from t.users where kind = 'Elixir.Foo.Bar'::atom;")
    end

    test "atom literals in compound predicates" do
      assert %Logical.Select{
               predicates: [{:cmp, :==, :status, :active}, {:cmp, :==, :name, "Alice"}]
             } =
               parse("select id from t.users where status = 'active'::atom and name = 'Alice';")

      assert %Logical.Select{predicates: [{:in, :status, [:active, :pending]}]} =
               parse("select id from t.users where status in ('active'::atom, 'pending'::atom);")

      assert %Logical.Select{predicates: [{:cmp, :>=, :status, :a}, {:cmp, :<, :status, :m}]} =
               parse("select id from t.users where status >= 'a'::atom and status < 'm'::atom;")
    end

    test "timestamp literal is a NaiveDateTime" do
      assert %Logical.Select{predicates: [{:cmp, :>=, :at, ~N[2024-03-01 12:34:56]}]} =
               parse("select id from t.users where at >= '2024-03-01 12:34:56'::timestamp;")

      assert %Logical.Select{predicates: [{:cmp, :>=, :at, ~N[2024-03-01 12:34:56.123456]}]} =
               parse(
                 "select id from t.users where at >= '2024-03-01T12:34:56.123456'::timestamp;"
               )

      assert %Logical.Select{predicates: [{:cmp, :>=, :at, ~N[2024-03-01 00:00:00]}]} =
               parse("select id from t.users where at >= cast('2024-03-01' as timestamp);")

      assert %Logical.Select{predicates: [{:cmp, :>=, :at, ~N[2024-03-01 12:34:56]}]} =
               parse("select id from t.users where at >= '2024-03-01 12:34:56'::naive_datetime;")
    end

    test "timestamp literal rejects a time zone offset" do
      assert_raise Unsupported, ~r/use timestamptz/, fn ->
        parse("select id from t.users where at >= '2024-03-01 12:34:56Z'::timestamp;")
      end
    end

    test "timestamptz literal is a UTC DateTime" do
      assert %Logical.Select{predicates: [{:cmp, :>=, :at, ~U[2024-03-01 12:34:56Z]}]} =
               parse("select id from t.users where at >= '2024-03-01 12:34:56Z'::timestamptz;")

      assert %Logical.Select{predicates: [{:cmp, :>=, :at, ~U[2024-03-01 10:34:56Z]}]} =
               parse(
                 "select id from t.users where at >= '2024-03-01T12:34:56+02:00'::timestamptz;"
               )

      assert %Logical.Select{predicates: [{:cmp, :>=, :at, ~U[2024-03-01 12:34:56Z]}]} =
               parse("select id from t.users where at >= '2024-03-01 12:34:56'::utc_datetime;")

      assert %Logical.Select{predicates: [{:cmp, :<, :at, ~U[2024-03-01 00:00:00Z]}]} =
               parse("select id from t.users where at < '2024-03-01'::timestamptz;")
    end

    test "date literal is a Date" do
      assert %Logical.Select{predicates: [{:cmp, :==, :day, ~D[2024-03-01]}]} =
               parse("select id from t.users where day = '2024-03-01'::date;")

      assert %Logical.Select{predicates: [{:in, :day, [~D[2024-03-01], ~D[2024-03-02]]}]} =
               parse(
                 "select id from t.users where day in (cast('2024-03-01' as date), '2024-03-02'::date);"
               )
    end

    test "time literal is a Time" do
      assert %Logical.Select{predicates: [{:cmp, :>=, :at, ~T[12:34:56]}]} =
               parse("select id from t.users where at >= '12:34:56'::time;")

      assert %Logical.Select{predicates: [{:cmp, :>=, :at, ~T[12:34:56.123456]}]} =
               parse("select id from t.users where at >= '12:34:56.123456'::time;")
    end

    test "malformed date and time raise" do
      assert_raise Unsupported, ~r/Cannot cast "2024-02-30" to date/, fn ->
        parse("select id from t.users where day = '2024-02-30'::date;")
      end

      assert_raise Unsupported, ~r/Cannot cast "25:00:00" to time/, fn ->
        parse("select id from t.users where at = '25:00:00'::time;")
      end
    end

    test "malformed timestamp raises" do
      assert_raise Unsupported, ~r/Cannot cast "yesterday" to timestamp/, fn ->
        parse("select id from t.users where at >= 'yesterday'::timestamp;")
      end
    end

    test "unknown type raises" do
      assert_raise Unsupported, ~r/Unknown type 'widget'/, fn ->
        parse("select id from t.users where status = 'active'::widget;")
      end
    end

    test "atom cast of a non-string raises" do
      assert_raise Unsupported, ~r/Cannot cast 1 to atom/, fn ->
        parse("select id from t.users where status = 1::atom;")
      end
    end

    test "like on an atom raises" do
      assert_raise Unsupported, fn ->
        parse("select id from t.users where status like 'a%'::atom;")
      end
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
