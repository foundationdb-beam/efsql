defmodule Efsql.SQL.ParserTest do
  use ExUnit.Case, async: true

  alias Efsql.SQL.AST.Select
  alias Efsql.SQL.Parser
  alias Efsql.SQL.SyntaxError

  defp parse(sql) do
    assert {:ok, %Select{} = select} = Parser.parse(sql)
    select
  end

  defp where(condition), do: parse("select a from t where #{condition}").where

  defp error(sql) do
    assert {:error, %SyntaxError{} = e} = Parser.parse(sql)
    e
  end

  defp reason(sql), do: error(sql).reason

  describe "statement" do
    test "the smallest query" do
      assert parse("select * from t") ==
               %Select{fields: :star, from: ["t"], where: nil, order_by: [], limit: nil}
    end

    test "every clause" do
      assert parse("select a, b from s.t where a = 1 order by b desc limit 5;") ==
               %Select{
                 fields: ["a", "b"],
                 from: ["s", "t"],
                 where: {:compare, :=, {:column, "a"}, {:literal, 1}},
                 order_by: [{"b", :desc}],
                 limit: 5
               }
    end

    test "the semicolon is optional" do
      assert parse("select * from t") == parse("select * from t;")
    end

    test "keywords are case-insensitive, names fold to lower case" do
      assert parse("SELECT Id FROM Tenant.Users WHERE Name = 'Al' ORDER BY Id DESC LIMIT 1") ==
               parse("select id from tenant.users where name = 'Al' order by id desc limit 1")
    end

    test "quoted names keep their case" do
      assert %Select{fields: ["Id"], from: ["My Tenant", "Users"]} =
               parse(~s(select "Id" from "My Tenant"."Users"))
    end

    test "comments and whitespace anywhere" do
      assert parse("""
             -- leading comment
             select /* fields */ a,
                    b
             from t -- table
             where a = 1 /* trailing */ ;
             """) == parse("select a, b from t where a = 1")
    end
  end

  describe "FROM" do
    test "one, two or three parts" do
      assert %Select{from: ["t"]} = parse("select * from t")
      assert %Select{from: ["tenant", "t"]} = parse("select * from tenant.t")

      assert %Select{from: ["storage", "tenant", "t"]} =
               parse("select * from storage.tenant.t")
    end

    test "any non-reserved word is a name" do
      assert %Select{from: ["user", "date"]} = parse("select * from user.date")
    end

    test "four parts is too many" do
      assert reason("select * from a.b.c.d") =~ "at most three parts"
    end

    test "more than one table" do
      assert reason("select * from a, b") == "expected the end of the statement, got ','"
    end
  end

  describe "SELECT list" do
    test "star or names" do
      assert %Select{fields: :star} = parse("select * from t")
      assert %Select{fields: ["a", "b", "_"]} = parse("select a, b, _ from t")
    end

    test "star can't be mixed with names" do
      assert reason("select *, a from t") == "expected FROM, got ','"
    end

    test "unsupported shapes say what is unsupported" do
      assert reason("select distinct a from t") == "DISTINCT is not supported"
      assert reason("select t.a from t") == "qualified column names are not supported"
    end

    test "a missing FROM" do
      assert %SyntaxError{
               reason: "expected FROM, '(' or ',', got the end of the statement",
               column: 9
             } =
               error("select a")
    end
  end

  describe "comparisons" do
    for {sql, op} <- [
          {"=", :=},
          {"<>", :<>},
          {"!=", :<>},
          {"<", :<},
          {">", :>},
          {"<=", :<=},
          {">=", :>=}
        ] do
      test "#{sql}" do
        assert where("a #{unquote(sql)} 1") ==
                 {:compare, unquote(op), {:column, "a"}, {:literal, 1}}
      end
    end

    test "either side can be the value" do
      assert where("1 < a") == {:compare, :<, {:literal, 1}, {:column, "a"}}
    end

    test "literals" do
      assert where("a = 'x'") == {:compare, :=, {:column, "a"}, {:literal, "x"}}
      assert where("a = -3") == {:compare, :=, {:column, "a"}, {:literal, -3}}
      assert where("a = +3") == {:compare, :=, {:column, "a"}, {:literal, 3}}
      assert where("a = -1.5") == {:compare, :=, {:column, "a"}, {:literal, -1.5}}
      assert where("a = true") == {:compare, :=, {:column, "a"}, {:literal, true}}
      assert where("a = FALSE") == {:compare, :=, {:column, "a"}, {:literal, false}}
      assert where("a = null") == {:compare, :=, {:column, "a"}, {:literal, nil}}
    end

    test "a sign only goes on a number" do
      assert reason("select a from t where a = -b") =~ "only supported on a number"
    end

    test "arithmetic is refused, not misread" do
      assert reason("select a from t where a = 1 + 2") == "arithmetic is not supported"
      assert reason("select a from t where a + 1 = 2") == "arithmetic is not supported"
    end

    test "comparisons don't chain" do
      assert reason("select a from t where a = 1 = 2") =~
               "expected the end of the statement, got '='"
    end
  end

  describe "predicates" do
    test "BETWEEN binds its own AND" do
      assert where("a between 1 and 2 and b = 3") ==
               {:and, {:between, {:column, "a"}, {:literal, 1}, {:literal, 2}, false},
                {:compare, :=, {:column, "b"}, {:literal, 3}}}
    end

    test "NOT BETWEEN" do
      assert where("a not between 1 and 2") ==
               {:between, {:column, "a"}, {:literal, 1}, {:literal, 2}, true}
    end

    test "IN and NOT IN" do
      assert where("a in (1, 'b', 2.5)") ==
               {:in, {:column, "a"}, [{:literal, 1}, {:literal, "b"}, {:literal, 2.5}], false}

      assert where("a not in ('x')") == {:in, {:column, "a"}, [{:literal, "x"}], true}
    end

    test "subqueries are named as unsupported" do
      assert reason("select a from t where a in (select b from u)") ==
               "subqueries are not supported"
    end

    test "IN needs a parenthesized, non-empty list" do
      assert reason("select a from t where a in ()") == "expected an expression, got ')'"
      assert reason("select a from t where a in 1") == "expected '(', got the number 1"

      assert reason("select a from t where a in (1, 2") ==
               "expected an operator, ')' or ',', got the end of the statement"
    end

    test "LIKE, NOT LIKE, ILIKE" do
      assert where("a like 'x%'") == {:like, {:column, "a"}, {:literal, "x%"}, false}
      assert where("a not like 'x%'") == {:like, {:column, "a"}, {:literal, "x%"}, true}
      assert where("a ilike 'x%'") == {:ilike, {:column, "a"}, {:literal, "x%"}, false}
    end

    test "IS [NOT] NULL, ISNULL, NOTNULL" do
      assert where("a is null") == {:is_null, {:column, "a"}, false}
      assert where("a is not null") == {:is_null, {:column, "a"}, true}
      assert where("a isnull") == {:is_null, {:column, "a"}, false}
      assert where("a notnull") == {:is_null, {:column, "a"}, true}
    end

    test "IS takes only NULL" do
      assert reason("select a from t where a is true") ==
               "expected NOT or NULL, got 'true'"

      assert reason("select a from t where a is not 1") == "expected NULL, got the number 1"
    end

    test "a bare operand is kept for the translator to reject" do
      assert where("a") == {:column, "a"}
    end
  end

  describe "boolean structure" do
    test "AND binds tighter than OR" do
      assert where("a = 1 or b = 2 and c = 3") ==
               {:or, {:compare, :=, {:column, "a"}, {:literal, 1}},
                {:and, {:compare, :=, {:column, "b"}, {:literal, 2}},
                 {:compare, :=, {:column, "c"}, {:literal, 3}}}}
    end

    test "AND and OR are left-associative" do
      assert {:and, {:and, _, _}, _} = where("a = 1 and b = 2 and c = 3")
      assert {:or, {:or, _, _}, _} = where("a = 1 or b = 2 or c = 3")
    end

    test "NOT binds tighter than AND" do
      assert where("not a = 1 and b = 2") ==
               {:and, {:not, {:compare, :=, {:column, "a"}, {:literal, 1}}},
                {:compare, :=, {:column, "b"}, {:literal, 2}}}
    end

    test "parentheses group and then vanish" do
      assert where("(a = 1 or b = 2) and c = 3") ==
               {:and,
                {:or, {:compare, :=, {:column, "a"}, {:literal, 1}},
                 {:compare, :=, {:column, "b"}, {:literal, 2}}},
                {:compare, :=, {:column, "c"}, {:literal, 3}}}

      assert where("((a = 1))") == where("a = 1")
    end

    test "unbalanced parentheses" do
      assert reason("select a from t where (a = 1") =~ "')'"

      assert reason("select a from t where a = 1)") =~
               "expected the end of the statement, got ')'"
    end

    # yecc keeps its own stack, so nesting has no limit.
    test "deep nesting" do
      deep = String.duplicate("(", 10_000) <> "a = 1" <> String.duplicate(")", 10_000)
      assert where(deep) == where("a = 1")
      assert {:not, {:not, _}} = where(String.duplicate("not ", 10_000) <> "a")
    end
  end

  describe "casts" do
    test "postfix and CAST forms give the same tree" do
      assert where("a = 'x'::atom") ==
               {:compare, :=, {:column, "a"}, {:cast, {:literal, "x"}, "atom"}}

      assert where("a = cast('x' as atom)") == where("a = 'x'::atom")
    end

    test "type names fold and may be reserved words" do
      assert {:compare, :=, _, {:cast, _, "date"}} = where("a = '2024-01-01'::DATE")
      assert {:compare, :=, _, {:cast, _, "time"}} = where("a = '10:00:00'::time")
    end

    test "timestamp with/without time zone" do
      assert {:compare, :=, _, {:cast, _, "timestamptz"}} =
               where("a = 'x'::timestamp with time zone")

      assert {:compare, :=, _, {:cast, _, "timestamp"}} =
               where("a = cast('x' as timestamp without time zone)")
    end

    test "casts chain, and apply to any operand" do
      assert where("a = 1::text::atom") ==
               {:compare, :=, {:column, "a"}, {:cast, {:cast, {:literal, 1}, "text"}, "atom"}}

      assert where("a::text = 'x'") ==
               {:compare, :=, {:cast, {:column, "a"}, "text"}, {:literal, "x"}}
    end

    test "casts inside IN and BETWEEN" do
      assert where("a in ('x'::atom, 'y'::atom)") ==
               {:in, {:column, "a"},
                [{:cast, {:literal, "x"}, "atom"}, {:cast, {:literal, "y"}, "atom"}], false}

      assert {:between, _, {:cast, _, "date"}, {:cast, _, "date"}, false} =
               where("a between '2024-01-01'::date and '2025-01-01'::date")
    end

    test "a cast needs a type" do
      assert reason("select a from t where a = 'x'::") =~ "expected a type name"

      assert reason("select a from t where a = cast('x' atom)") ==
               "expected an operator or AS, got 'atom'"

      assert reason("select a from t where a = cast('x' as atom") ==
               "expected ')', got the end of the statement"
    end
  end

  describe "tuples" do
    test "a partition scan" do
      assert where("_ = ('p', *)") ==
               {:compare, :=, {:column, "_"}, {:tuple, [{:literal, "p"}, :star]}}
    end

    test "a versionstamp" do
      assert where("_ >= ('p', 22348699227647901699)") ==
               {:compare, :>=, {:column, "_"},
                {:tuple, [{:literal, "p"}, {:literal, 22_348_699_227_647_901_699}]}}
    end

    test "star only inside a tuple" do
      assert reason("select a from t where a = (*)") == "expected ',', got ')'"
      assert reason("select a from t where a = *") =~ "expected an expression, got '*'"
    end
  end

  describe "reserved words" do
    test "common column names are not reserved" do
      for name <- ~w[day at user value date time timestamp year month zone key type level] do
        assert where("#{name} = 1") == {:compare, :=, {:column, name}, {:literal, 1}},
               "#{name} should be usable as a name"

        assert %Select{fields: [^name], order_by: [{^name, :desc}]} =
                 parse("select #{name} from t order by #{name} desc")
      end
    end

    test "reserved words need quotes, and the error says so" do
      assert reason("select order from t") =~
               ~s(got the keyword 'order' (quote it, "order")

      assert where(~s("order" = 1)) == {:compare, :=, {:column, "order"}, {:literal, 1}}

      assert %Select{fields: ["select", "from"]} =
               parse(~s(select "select", "from" from t))
    end

    test "the reserved list" do
      for word <- Parser.reserved_words() do
        assert {:error, %SyntaxError{}} = Parser.parse("select #{word} from t")
      end
    end
  end

  describe "GROUP BY and aggregates" do
    test "aggregates in the select list, with or without an alias" do
      assert %Select{
               fields: [
                 "a",
                 {:aggregate, "count", :star, nil},
                 {:aggregate, "sum", "price", "total"}
               ],
               group_by: ["a"]
             } = parse("select a, COUNT(*), Sum(price) as total from t group by a")
    end

    test "any function name parses; the translator checks it" do
      assert %Select{fields: [{:aggregate, "lower", "a", nil}]} = parse("select lower(a) from t")
    end

    test "GROUP BY lists names and comes between WHERE and ORDER BY" do
      assert %Select{where: {:compare, :=, _, _}, group_by: ["a", "b"], order_by: [{"a", :asc}]} =
               parse("select a, b from t where c = 1 group by a, b order by a limit 5")
    end

    test "ORDER BY takes an aggregate" do
      assert %Select{order_by: [{{:aggregate, "count", :star, nil}, :desc}, {"a", :asc}]} =
               parse("select a from t group by a order by count(*) desc, a")
    end

    test "errors" do
      assert reason("select * from t group a") == "expected BY, got 'a'"
      assert reason("select * from t group by") == "expected a name, got the end of the statement"
      assert reason("select count() from t") == "expected a name or '*', got ')'"
      assert reason("select count(a from t") == "expected ')', got 'from'"
      assert reason("select count(*) as from t") =~ "expected a name, got the keyword 'from'"

      assert reason("select a from t order by a group by a") ==
               "expected the end of the statement, got 'group'"

      assert reason("select a from t where count(*) > 1") ==
               "functions are only supported as aggregates, in the select list and ORDER BY"

      assert reason("select a from t group by a having count(*) > 1") ==
               "HAVING is not supported"
    end
  end

  describe "ORDER BY and LIMIT" do
    test "directions default to ascending" do
      assert %Select{order_by: [{"a", :asc}, {"b", :desc}, {"c", :asc}]} =
               parse("select * from t order by a, b desc, c asc")
    end

    test "ORDER needs BY and a field" do
      assert reason("select * from t order a") == "expected BY, got 'a'"
      assert reason("select * from t order by") == "expected a name, got the end of the statement"

      assert reason("select * from t order by a nulls first") ==
               "expected the end of the statement, got 'nulls'"
    end

    test "LIMIT takes a whole number" do
      assert %Select{limit: 0} = parse("select * from t limit 0")
      assert reason("select * from t limit -1") == "expected a whole number, got '-'"
      assert reason("select * from t limit 1.5") =~ "got the number 1.5"
      assert reason("select * from t limit") =~ "got the end of the statement"
    end

    test "clauses in the wrong order" do
      assert reason("select * from t limit 1 where a = 1") =~
               "expected the end of the statement, got 'where'"

      assert reason("select * from t order by a where a = 1") =~ "got 'where'"
    end
  end

  describe "statement errors" do
    test "empty input" do
      assert reason("") == "empty statement"
      assert reason("  -- just a comment\n") == "empty statement"
      assert reason(";") =~ "expected SELECT, got ';'"
    end

    test "only SELECT" do
      assert reason("delete from t") == "only SELECT statements are supported"
      assert reason("update t set a = 1") == "only SELECT statements are supported"
      assert reason("with x as (select 1) select * from x") == "WITH is not supported"
    end

    test "one statement" do
      assert %SyntaxError{reason: "only one statement is supported", column: 18} =
               error("select * from t; select * from u")

      assert reason("select * from t;;") == "only one statement is supported"
    end

    test "unsupported clauses are named" do
      assert reason("select * from t where a = 1 having a > 1") ==
               "HAVING is not supported"

      assert reason("select * from t limit 1 offset 2") == "OFFSET is not supported"
      assert reason("select * from t join u on t.a = u.a") == "JOIN is not supported"
      assert reason("select * from t left join u on a = b") == "JOIN is not supported"
      assert reason("select * from t union select * from u") == "UNION is not supported"
    end

    test "errors point at the offending token" do
      assert %SyntaxError{line: 3, column: 10, reason: "expected an expression, got '='"} =
               error("select a\nfrom t\nwhere a ==  1")

      assert %SyntaxError{
               line: 1,
               column: 23,
               reason: "expected an expression, got the end of the statement"
             } =
               error("select a from t where ")
    end

    test "long strings are truncated in messages" do
      assert reason("select * from t limit '#{String.duplicate("x", 100)}'") =~
               "the string 'xxxxxxxxxxxxxxxxxxxx...'"
    end

    test "parse! raises the error" do
      assert_raise SyntaxError, ~r/line 1, column 1: expected SELECT/, fn ->
        Parser.parse!("selec * from t")
      end
    end
  end
end
