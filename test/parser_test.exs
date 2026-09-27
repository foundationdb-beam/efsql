defmodule Efsql.ParserTest do
  use ExUnit.Case, async: true

  alias Efsql.Exception.Unsupported
  alias Efsql.Logical
  alias Efsql.Parser

  defp parse(sql), do: Parser.sql_to_logical(sql)

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

  describe "every tenant" do
    test "* for the tenant reads every tenant of a storage id" do
      assert %Logical.Select{prefix: {:all_tenants, nil}, source: "users"} =
               parse("select id from *.users;")

      assert %Logical.Select{prefix: {:all_tenants, "customer"}, source: "users"} =
               parse("select id from customer.*.users;")
    end

    test "_tenant is a field of a query across tenants" do
      assert %Logical.Select{
               projection: [:_tenant, :"count(*)"],
               predicates: [{:in, :_tenant, ["a", "b"]}],
               group_by: [:_tenant],
               order: [asc: :_tenant]
             } =
               parse(
                 "select _tenant, count(*) from *.users where _tenant in ('a', 'b') " <>
                   "group by _tenant order by _tenant;"
               )
    end

    test "_tenant anywhere else is unsupported" do
      for sql <- [
            "select _tenant from t.users;",
            "select id from t.users where _tenant = 'a';",
            "select id from t.users order by _tenant;",
            "select count(*) from t.users group by _tenant;",
            "select count(_tenant) from t.users;"
          ] do
        assert_raise Unsupported, ~r/_tenant is only available in a query across tenants/, fn ->
          parse(sql)
        end
      end
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

    test "is null and is not null" do
      assert %Logical.Select{predicates: [{:is_null, :notes}]} =
               parse("select id from t.users where notes is null;")

      assert %Logical.Select{predicates: [{:not_null, :notes}]} =
               parse("select id from t.users where notes is not null;")

      assert %Logical.Select{predicates: [{:is_null, :notes}]} =
               parse("select id from t.users where notes isnull;")

      assert %Logical.Select{predicates: [{:not_null, :notes}]} =
               parse("select id from t.users where notes notnull;")
    end

    # Regression: the previous parser library never returned on some of these.
    test "null tests combine with other predicates in any position" do
      assert %Logical.Select{predicates: [{:cmp, :==, :name, "a"}, {:not_null, :notes}]} =
               parse("select id from t.users where name = 'a' and notes is not null;")

      assert %Logical.Select{predicates: [{:not_null, :notes}, {:cmp, :==, :name, "a"}]} =
               parse("select id from t.users where notes is not null and name = 'a';")

      assert %Logical.Select{
               predicates: [{:is_null, :a}, {:not_null, :b}, {:cmp, :==, :c, "x"}]
             } = parse("select id from t.users where a is null and b notnull and c = 'x';")

      assert %Logical.Select{predicates: [{:cmp, :==, :c, "x"}, {:is_null, :a}]} =
               parse("select id from t.users where c = 'x' and a isnull;")
    end

    test "comparison with null raises" do
      assert_raise Unsupported, ~r/use IS NULL or IS NOT NULL/, fn ->
        parse("select id from t.users where notes = null;")
      end

      assert_raise Unsupported, ~r/use IS NULL or IS NOT NULL/, fn ->
        parse("select id from t.users where notes in ('a', null);")
      end
    end

    test "the primary key is never null" do
      assert_raise Unsupported, ~r/never NULL/, fn ->
        parse("select id from t.users where _ is null;")
      end
    end

    # Regression: the previous parser library hung or misparsed these.
    test "columns named after reserved words" do
      assert %Logical.Select{predicates: [{:cmp, :==, :day, "x"}]} =
               parse("select id from t.users where day = 'x';")

      assert %Logical.Select{predicates: [{:cmp, :==, :x, "a"}, {:cmp, :>=, :at, 1}]} =
               parse("select id from t.users where x = 'a' and at >= 1;")

      assert %Logical.Select{
               predicates: [
                 {:in, :day, ["a"]},
                 {:like, :user, "a%"},
                 {:not_like, :value, "b%"},
                 {:range, :year, {:>=, 1}, {:<=, 2}}
               ]
             } =
               parse(
                 "select id from t.users where day in ('a') and user like 'a%' and value not like 'b%' and year between 1 and 2;"
               )

      assert %Logical.Select{predicates: [{:is_null, :day}, {:not_null, :at}]} =
               parse("select id from t.users where day is null and at is not null;")
    end

    test "reserved-word columns keep their sort direction" do
      assert %Logical.Select{order: [desc: :day, asc: :user]} =
               parse("select id from t.users order by day desc, user asc;")
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

  describe "group by" do
    test "group fields and aggregates become output columns" do
      assert %Logical.Select{
               projection: [:notes, :"count(*)", :total],
               group_by: [:notes],
               aggregates: [{:"count(*)", :count, :star}, {:total, :sum, :price}]
             } = parse("select notes, count(*), sum(price) as total from t.users group by notes;")
    end

    test "an aggregate without GROUP BY is one group over every row" do
      assert %Logical.Select{group_by: [], aggregates: [{:"max(name)", :max, :name}]} =
               parse("select max(name) from t.users;")
    end

    test "every aggregate function" do
      assert %Logical.Select{aggregates: aggregates} =
               parse("select count(a), sum(a), min(a), max(a), avg(a) from t.users;")

      assert Enum.map(aggregates, &elem(&1, 1)) == [:count, :sum, :min, :max, :avg]
    end

    test "ORDER BY names a group field, an aggregate or its alias" do
      assert %Logical.Select{order: [desc: :n, asc: :notes, desc: :"max(name)"]} =
               parse(
                 "select notes, count(*) as n, max(name) from t.users group by notes " <>
                   "order by n desc, notes, max(name) desc;"
               )
    end

    test "an aggregate only in ORDER BY is computed and projected away" do
      assert %Logical.Select{
               projection: [:notes],
               aggregates: [{:"count(*)", :count, :star}],
               order: [desc: :"count(*)"]
             } = parse("select notes from t.users group by notes order by count(*) desc;")
    end

    test "the same aggregate in ORDER BY is the selected one, alias included" do
      assert %Logical.Select{aggregates: [{:n, :count, :star}], order: [desc: :n]} =
               parse("select count(*) as n from t.users order by count(*) desc;")
    end

    test "WHERE and LIMIT carry over" do
      assert %Logical.Select{predicates: [{:cmp, :==, :name, "x"}], limit: 5} =
               parse("select count(*) from t.users where name = 'x' limit 5;")
    end

    test "grouping errors say what is wrong" do
      for {sql, message} <- [
            {"select name, count(*) from t.users", "name must be in GROUP BY"},
            {"select name from t.users group by notes", "name must be in GROUP BY"},
            {"select * from t.users group by name", "SELECT * can't be used with GROUP BY"},
            {"select count(*) from t.users order by name", "ORDER BY name must name"},
            {"select lower(name) from t.users", "lower() is not supported"},
            {"select sum(*) from t.users", "only count takes *"},
            {"select count(_) from t.users", "count('_') is not supported"},
            {"select count(*) from t.users group by _", "GROUP BY '_' is not supported"}
          ] do
        assert_raise Unsupported, ~r/#{Regex.escape(message)}/, fn -> parse(sql) end
      end
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

  describe "translation" do
    test "parentheses around ANDed conditions flatten" do
      assert %Logical.Select{
               predicates: [{:cmp, :==, :a, 1}, {:cmp, :==, :b, 2}, {:cmp, :==, :c, 3}]
             } =
               parse("select id from t.users where (a = 1 and (b = 2)) and c = 3;")
    end

    test "typed literals as BETWEEN bounds" do
      assert %Logical.Select{
               predicates: [
                 {:range, :at, {:>=, ~N[2024-01-01 00:00:00]}, {:<=, ~N[2025-01-01 00:00:00]}}
               ]
             } =
               parse(
                 "select id from t.users where at between '2024-01-01'::timestamp and '2025-01-01'::timestamp;"
               )
    end

    test "<> and != are inequalities, either way round" do
      for condition <- ["age <> 40", "age != 40", "40 <> age"] do
        assert %Logical.Select{predicates: [{:cmp, :!=, :age, 40}]} =
                 parse("select id from t.users where #{condition};")
      end
    end

    test "NOT IN, NOT BETWEEN, ILIKE and NOT ILIKE" do
      assert %Logical.Select{
               predicates: [
                 {:not_in, :a, [1, 2]},
                 {:not_range, :b, {:>=, 1}, {:<=, 5}},
                 {:ilike, :c, "al%"},
                 {:not_ilike, :d, "x_"}
               ]
             } =
               parse(
                 "select id from t.users where a not in (1, 2) and b not between 1 and 5 " <>
                   "and c ilike 'al%' and d not ilike 'x_';"
               )
    end

    test "NOT is pushed into the condition it negates" do
      for {condition, predicates} <- [
            {"not (a = 1)", [{:cmp, :!=, :a, 1}]},
            {"not a <> 1", [{:cmp, :==, :a, 1}]},
            {"not a < 1", [{:cmp, :>=, :a, 1}]},
            {"not a >= 1", [{:cmp, :<, :a, 1}]},
            {"not a > 1", [{:cmp, :<=, :a, 1}]},
            {"not a <= 1", [{:cmp, :>, :a, 1}]},
            {"not not a = 1", [{:cmp, :==, :a, 1}]},
            {"not a in (1, 2)", [{:not_in, :a, [1, 2]}]},
            {"not a not in (1, 2)", [{:in, :a, [1, 2]}]},
            {"not (a between 1 and 5)", [{:not_range, :a, {:>=, 1}, {:<=, 5}}]},
            {"not a like 'x%'", [{:not_like, :a, "x%"}]},
            {"not a ilike 'x%'", [{:not_ilike, :a, "x%"}]},
            {"not (a is null)", [{:not_null, :a}]},
            {"not a isnull", [{:not_null, :a}]},
            {"not (a = 1 or b like 'x%')", [{:cmp, :!=, :a, 1}, {:not_like, :b, "x%"}]},
            {"c = 2 and not (a = 1 or not b = 3)",
             [{:cmp, :==, :c, 2}, {:cmp, :!=, :a, 1}, {:cmp, :==, :b, 3}]}
          ] do
        assert %Logical.Select{predicates: ^predicates} =
                 parse("select id from t.users where #{condition};"),
               condition
      end
    end

    test "a value on the left is flipped" do
      assert %Logical.Select{predicates: [{:cmp, :>, :age, 40}, {:cmp, :==, :name, "x"}]} =
               parse("select id from t.users where 40 < age and 'x' = name;")
    end

    test "unsupported conditions say what is unsupported" do
      for {condition, message} <- [
            {"a = 1 or b = 2", "OR is not supported"},
            {"not (a = 1 and b = 2)", "OR is not supported"},
            {"not a", "the field a is not a condition; NOT needs a condition"},
            {"a ilike 1", "an ILIKE pattern must be a string"},
            {"a = b", "comparing two fields"},
            {"1 = 1", "needs a field on one side"},
            {"'x' in ('x')", "IN needs a field on its left"},
            {"a", "the field a is not a condition"},
            {"a = (1, 2)", "a tuple must be"},
            {"_ = ('p', -1)", "versionstamp is a whole number from 0 to 2^96 - 1"},
            {"_ = ('p', #{Bitwise.bsl(1, 96)})", "versionstamp is a whole number"}
          ] do
        assert_raise Unsupported, ~r/#{Regex.escape(message)}/, fn ->
          parse("select id from t.users where #{condition};")
        end
      end
    end

    test "field names longer than an atom allows" do
      long = String.duplicate("x", 256)

      assert_raise Unsupported, ~r/limited to 255 characters/, fn ->
        parse(~s(select "#{long}" from t.users;))
      end

      assert %Logical.Select{projection: [_]} =
               parse(~s(select "#{String.duplicate("x", 255)}" from t.users;))
    end

    test "syntax errors are SyntaxErrors" do
      assert_raise Efsql.SQL.SyntaxError, ~r/line 1, column 27: expected an expression/, fn ->
        parse("select id from t where a =;")
      end
    end

    test "every example on the help page parses" do
      examples =
        for line <- Efsql.Tui.Help.lines(),
            {:accent, "   " <> text} <- line,
            String.starts_with?(text, "select "),
            do: text

      assert length(examples) >= 9

      for sql <- examples do
        assert %Logical.Select{} = parse(sql)
      end
    end
  end
end
