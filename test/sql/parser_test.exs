defmodule Efsql.SQL.ParserTest do
  # Every test runs against both parsers: the hand-written recursive
  # descent one and the one built on leex and yecc. They share a contract:
  # the same tree, and the same error message at the same position.
  use ExUnit.Case,
    async: true,
    parameterize: [%{parser: Efsql.SQL.Parser}, %{parser: Efsql.SQL.Yecc}]

  alias Efsql.SQL.AST.Select
  alias Efsql.SQL.Parser
  alias Efsql.SQL.SyntaxError

  defp parse(parser, sql) do
    assert {:ok, %Select{} = select} = parser.parse(sql)
    select
  end

  defp where(parser, condition), do: parse(parser, "select a from t where #{condition}").where

  defp error(parser, sql) do
    assert {:error, %SyntaxError{} = e} = parser.parse(sql)
    e
  end

  defp reason(parser, sql), do: error(parser, sql).reason

  describe "statement" do
    test "the smallest query", %{parser: parser} do
      assert parse(parser, "select * from t") ==
               %Select{fields: :star, from: ["t"], where: nil, order_by: [], limit: nil}
    end

    test "every clause", %{parser: parser} do
      assert parse(parser, "select a, b from s.t where a = 1 order by b desc limit 5;") ==
               %Select{
                 fields: ["a", "b"],
                 from: ["s", "t"],
                 where: {:compare, :=, {:column, "a"}, {:literal, 1}},
                 order_by: [{"b", :desc}],
                 limit: 5
               }
    end

    test "the semicolon is optional", %{parser: parser} do
      assert parse(parser, "select * from t") == parse(parser, "select * from t;")
    end

    test "keywords are case-insensitive, names fold to lower case", %{parser: parser} do
      assert parse(
               parser,
               "SELECT Id FROM Tenant.Users WHERE Name = 'Al' ORDER BY Id DESC LIMIT 1"
             ) ==
               parse(
                 parser,
                 "select id from tenant.users where name = 'Al' order by id desc limit 1"
               )
    end

    test "quoted names keep their case", %{parser: parser} do
      assert %Select{fields: ["Id"], from: ["My Tenant", "Users"]} =
               parse(parser, ~s(select "Id" from "My Tenant"."Users"))
    end

    test "comments and whitespace anywhere", %{parser: parser} do
      assert parse(parser, """
             -- leading comment
             select /* fields */ a,
                    b
             from t -- table
             where a = 1 /* trailing */ ;
             """) == parse(parser, "select a, b from t where a = 1")
    end
  end

  describe "FROM" do
    test "one, two or three parts", %{parser: parser} do
      assert %Select{from: ["t"]} = parse(parser, "select * from t")
      assert %Select{from: ["tenant", "t"]} = parse(parser, "select * from tenant.t")

      assert %Select{from: ["storage", "tenant", "t"]} =
               parse(parser, "select * from storage.tenant.t")
    end

    test "any non-reserved word is a name", %{parser: parser} do
      assert %Select{from: ["user", "date"]} = parse(parser, "select * from user.date")
    end

    test "four parts is too many", %{parser: parser} do
      assert reason(parser, "select * from a.b.c.d") =~ "at most three parts"
    end

    test "more than one table", %{parser: parser} do
      assert reason(parser, "select * from a, b") =~ "more than one table"
    end
  end

  describe "SELECT list" do
    test "star or names", %{parser: parser} do
      assert %Select{fields: :star} = parse(parser, "select * from t")
      assert %Select{fields: ["a", "b", "_"]} = parse(parser, "select a, b, _ from t")
    end

    test "star can't be mixed with names", %{parser: parser} do
      assert reason(parser, "select *, a from t") =~ "can't be combined"
    end

    test "unsupported shapes say what is unsupported", %{parser: parser} do
      assert reason(parser, "select distinct a from t") == "DISTINCT is not supported"
      assert reason(parser, "select count(a) from t") == "functions are not supported"
      assert reason(parser, "select t.a from t") == "qualified column names are not supported"
    end

    test "a missing FROM", %{parser: parser} do
      assert %SyntaxError{reason: "expected FROM, got the end of the statement", column: 9} =
               error(parser, "select a")
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
      test "#{sql}", %{parser: parser} do
        assert where(parser, "a #{unquote(sql)} 1") ==
                 {:compare, unquote(op), {:column, "a"}, {:literal, 1}}
      end
    end

    test "either side can be the value", %{parser: parser} do
      assert where(parser, "1 < a") == {:compare, :<, {:literal, 1}, {:column, "a"}}
    end

    test "literals", %{parser: parser} do
      assert where(parser, "a = 'x'") == {:compare, :=, {:column, "a"}, {:literal, "x"}}
      assert where(parser, "a = -3") == {:compare, :=, {:column, "a"}, {:literal, -3}}
      assert where(parser, "a = +3") == {:compare, :=, {:column, "a"}, {:literal, 3}}
      assert where(parser, "a = -1.5") == {:compare, :=, {:column, "a"}, {:literal, -1.5}}
      assert where(parser, "a = true") == {:compare, :=, {:column, "a"}, {:literal, true}}
      assert where(parser, "a = FALSE") == {:compare, :=, {:column, "a"}, {:literal, false}}
      assert where(parser, "a = null") == {:compare, :=, {:column, "a"}, {:literal, nil}}
    end

    test "a sign only goes on a number", %{parser: parser} do
      assert reason(parser, "select a from t where a = -b") =~ "only supported on a number"
    end

    test "arithmetic is refused, not misread", %{parser: parser} do
      assert reason(parser, "select a from t where a = 1 + 2") == "arithmetic is not supported"
      assert reason(parser, "select a from t where a + 1 = 2") == "arithmetic is not supported"
    end

    test "comparisons don't chain", %{parser: parser} do
      assert reason(parser, "select a from t where a = 1 = 2") =~
               "expected end of statement, got '='"
    end
  end

  describe "predicates" do
    test "BETWEEN binds its own AND", %{parser: parser} do
      assert where(parser, "a between 1 and 2 and b = 3") ==
               {:and, {:between, {:column, "a"}, {:literal, 1}, {:literal, 2}, false},
                {:compare, :=, {:column, "b"}, {:literal, 3}}}
    end

    test "NOT BETWEEN", %{parser: parser} do
      assert where(parser, "a not between 1 and 2") ==
               {:between, {:column, "a"}, {:literal, 1}, {:literal, 2}, true}
    end

    test "IN and NOT IN", %{parser: parser} do
      assert where(parser, "a in (1, 'b', 2.5)") ==
               {:in, {:column, "a"}, [{:literal, 1}, {:literal, "b"}, {:literal, 2.5}], false}

      assert where(parser, "a not in ('x')") == {:in, {:column, "a"}, [{:literal, "x"}], true}
    end

    test "subqueries are named as unsupported", %{parser: parser} do
      assert reason(parser, "select a from t where a in (select b from u)") ==
               "subqueries are not supported"
    end

    test "IN needs a parenthesized, non-empty list", %{parser: parser} do
      assert reason(parser, "select a from t where a in ()") == "IN needs at least one value"
      assert reason(parser, "select a from t where a in 1") =~ "expected '(' after IN"
      assert reason(parser, "select a from t where a in (1, 2") =~ "')' to close the IN list"
    end

    test "LIKE, NOT LIKE, ILIKE", %{parser: parser} do
      assert where(parser, "a like 'x%'") == {:like, {:column, "a"}, {:literal, "x%"}, false}
      assert where(parser, "a not like 'x%'") == {:like, {:column, "a"}, {:literal, "x%"}, true}
      assert where(parser, "a ilike 'x%'") == {:ilike, {:column, "a"}, {:literal, "x%"}, false}
    end

    test "IS [NOT] NULL, ISNULL, NOTNULL", %{parser: parser} do
      assert where(parser, "a is null") == {:is_null, {:column, "a"}, false}
      assert where(parser, "a is not null") == {:is_null, {:column, "a"}, true}
      assert where(parser, "a isnull") == {:is_null, {:column, "a"}, false}
      assert where(parser, "a notnull") == {:is_null, {:column, "a"}, true}
    end

    test "IS takes only NULL", %{parser: parser} do
      assert reason(parser, "select a from t where a is true") =~
               "expected NULL after IS, got 'true'"

      assert reason(parser, "select a from t where a is not 1") =~ "expected NULL after IS NOT"
    end

    test "a bare operand is kept for the translator to reject", %{parser: parser} do
      assert where(parser, "a") == {:column, "a"}
    end
  end

  describe "boolean structure" do
    test "AND binds tighter than OR", %{parser: parser} do
      assert where(parser, "a = 1 or b = 2 and c = 3") ==
               {:or, {:compare, :=, {:column, "a"}, {:literal, 1}},
                {:and, {:compare, :=, {:column, "b"}, {:literal, 2}},
                 {:compare, :=, {:column, "c"}, {:literal, 3}}}}
    end

    test "AND and OR are left-associative", %{parser: parser} do
      assert {:and, {:and, _, _}, _} = where(parser, "a = 1 and b = 2 and c = 3")
      assert {:or, {:or, _, _}, _} = where(parser, "a = 1 or b = 2 or c = 3")
    end

    test "NOT binds tighter than AND", %{parser: parser} do
      assert where(parser, "not a = 1 and b = 2") ==
               {:and, {:not, {:compare, :=, {:column, "a"}, {:literal, 1}}},
                {:compare, :=, {:column, "b"}, {:literal, 2}}}
    end

    test "parentheses group and then vanish", %{parser: parser} do
      assert where(parser, "(a = 1 or b = 2) and c = 3") ==
               {:and,
                {:or, {:compare, :=, {:column, "a"}, {:literal, 1}},
                 {:compare, :=, {:column, "b"}, {:literal, 2}}},
                {:compare, :=, {:column, "c"}, {:literal, 3}}}

      assert where(parser, "((a = 1))") == where(parser, "a = 1")
    end

    test "unbalanced parentheses", %{parser: parser} do
      assert reason(parser, "select a from t where (a = 1") =~ "expected ')'"

      assert reason(parser, "select a from t where a = 1)") =~
               "expected end of statement, got ')'"
    end

    test "deep nesting", %{parser: parser} do
      assert where(parser, String.duplicate("(", 150) <> "a = 1" <> String.duplicate(")", 150)) ==
               where(parser, "a = 1")

      case parser do
        # Recursive descent caps its depth rather than risk the stack.
        Parser ->
          assert reason(parser, "select a from t where " <> String.duplicate("(", 10_000) <> "a") ==
                   "expression is nested too deeply"

          assert reason(
                   parser,
                   "select a from t where " <> String.duplicate("not ", 10_000) <> "a"
                 ) ==
                   "expression is nested too deeply"

        # yecc keeps its own stack, so it needs no limit.
        Efsql.SQL.Yecc ->
          deep = String.duplicate("(", 10_000) <> "a = 1" <> String.duplicate(")", 10_000)
          assert where(parser, deep) == where(parser, "a = 1")
          assert {:not, {:not, _}} = where(parser, String.duplicate("not ", 10_000) <> "a")
      end
    end
  end

  describe "casts" do
    test "postfix and CAST forms give the same tree", %{parser: parser} do
      assert where(parser, "a = 'x'::atom") ==
               {:compare, :=, {:column, "a"}, {:cast, {:literal, "x"}, "atom"}}

      assert where(parser, "a = cast('x' as atom)") == where(parser, "a = 'x'::atom")
    end

    test "type names fold and may be reserved words", %{parser: parser} do
      assert {:compare, :=, _, {:cast, _, "date"}} = where(parser, "a = '2024-01-01'::DATE")
      assert {:compare, :=, _, {:cast, _, "time"}} = where(parser, "a = '10:00:00'::time")
    end

    test "timestamp with/without time zone", %{parser: parser} do
      assert {:compare, :=, _, {:cast, _, "timestamptz"}} =
               where(parser, "a = 'x'::timestamp with time zone")

      assert {:compare, :=, _, {:cast, _, "timestamp"}} =
               where(parser, "a = cast('x' as timestamp without time zone)")
    end

    test "casts chain, and apply to any operand", %{parser: parser} do
      assert where(parser, "a = 1::text::atom") ==
               {:compare, :=, {:column, "a"}, {:cast, {:cast, {:literal, 1}, "text"}, "atom"}}

      assert where(parser, "a::text = 'x'") ==
               {:compare, :=, {:cast, {:column, "a"}, "text"}, {:literal, "x"}}
    end

    test "casts inside IN and BETWEEN", %{parser: parser} do
      assert where(parser, "a in ('x'::atom, 'y'::atom)") ==
               {:in, {:column, "a"},
                [{:cast, {:literal, "x"}, "atom"}, {:cast, {:literal, "y"}, "atom"}], false}

      assert {:between, _, {:cast, _, "date"}, {:cast, _, "date"}, false} =
               where(parser, "a between '2024-01-01'::date and '2025-01-01'::date")
    end

    test "a cast needs a type", %{parser: parser} do
      assert reason(parser, "select a from t where a = 'x'::") =~ "expected a type name"
      assert reason(parser, "select a from t where a = cast('x' atom)") =~ "expected AS in CAST"
      assert reason(parser, "select a from t where a = cast('x' as atom") =~ "')' to close CAST"
    end
  end

  describe "tuples" do
    test "a partition scan", %{parser: parser} do
      assert where(parser, "_ = ('p', *)") ==
               {:compare, :=, {:column, "_"}, {:tuple, [{:literal, "p"}, :star]}}
    end

    test "a versionstamp", %{parser: parser} do
      assert where(parser, "_ >= ('p', 22348699227647901699)") ==
               {:compare, :>=, {:column, "_"},
                {:tuple, [{:literal, "p"}, {:literal, 22_348_699_227_647_901_699}]}}
    end

    test "star only inside a tuple", %{parser: parser} do
      assert reason(parser, "select a from t where a = (*)") =~ "only allowed in a tuple"
      assert reason(parser, "select a from t where a = *") =~ "expected an expression, got '*'"
    end
  end

  describe "reserved words" do
    test "common column names are not reserved", %{parser: parser} do
      for name <- ~w[day at user value date time timestamp year month zone key type level] do
        assert where(parser, "#{name} = 1") == {:compare, :=, {:column, name}, {:literal, 1}},
               "#{name} should be usable as a name"

        assert %Select{fields: [^name], order_by: [{^name, :desc}]} =
                 parse(parser, "select #{name} from t order by #{name} desc")
      end
    end

    test "reserved words need quotes, and the error says so", %{parser: parser} do
      assert reason(parser, "select order from t") =~
               ~s(got the keyword 'order' (quote it, "order")

      assert where(parser, ~s("order" = 1)) == {:compare, :=, {:column, "order"}, {:literal, 1}}

      assert %Select{fields: ["select", "from"]} =
               parse(parser, ~s(select "select", "from" from t))
    end

    test "the reserved list", %{parser: parser} do
      for word <- Parser.reserved_words() do
        assert {:error, %SyntaxError{}} = parser.parse("select #{word} from t")
      end
    end
  end

  describe "ORDER BY and LIMIT" do
    test "directions default to ascending", %{parser: parser} do
      assert %Select{order_by: [{"a", :asc}, {"b", :desc}, {"c", :asc}]} =
               parse(parser, "select * from t order by a, b desc, c asc")
    end

    test "ORDER needs BY and a field", %{parser: parser} do
      assert reason(parser, "select * from t order a") =~ "expected BY after ORDER"
      assert reason(parser, "select * from t order by") =~ "expected a field name to order by"

      assert reason(parser, "select * from t order by a nulls first") ==
               "NULLS FIRST/LAST is not supported"
    end

    test "LIMIT takes a whole number", %{parser: parser} do
      assert %Select{limit: 0} = parse(parser, "select * from t limit 0")
      assert reason(parser, "select * from t limit -1") =~ "LIMIT expects a whole number, got '-'"
      assert reason(parser, "select * from t limit 1.5") =~ "got the number 1.5"
      assert reason(parser, "select * from t limit") =~ "got the end of the statement"
    end

    test "clauses in the wrong order", %{parser: parser} do
      assert reason(parser, "select * from t limit 1 where a = 1") =~
               "expected end of statement, got 'where'"

      assert reason(parser, "select * from t order by a where a = 1") =~ "got 'where'"
    end
  end

  describe "statement errors" do
    test "empty input", %{parser: parser} do
      assert reason(parser, "") == "empty statement"
      assert reason(parser, "  -- just a comment\n") == "empty statement"
      assert reason(parser, ";") =~ "expected SELECT, got ';'"
    end

    test "only SELECT", %{parser: parser} do
      assert reason(parser, "delete from t") == "only SELECT statements are supported"
      assert reason(parser, "update t set a = 1") == "only SELECT statements are supported"
      assert reason(parser, "with x as (select 1) select * from x") =~ "expected SELECT"
    end

    test "one statement", %{parser: parser} do
      assert %SyntaxError{reason: "only one statement is supported", column: 18} =
               error(parser, "select * from t; select * from u")

      assert reason(parser, "select * from t;;") == "only one statement is supported"
    end

    test "unsupported clauses are named", %{parser: parser} do
      assert reason(parser, "select * from t group by a") == "GROUP BY is not supported"

      assert reason(parser, "select * from t where a = 1 having a > 1") ==
               "HAVING is not supported"

      assert reason(parser, "select * from t limit 1 offset 2") == "OFFSET is not supported"
      assert reason(parser, "select * from t join u on t.a = u.a") == "JOIN is not supported"
      assert reason(parser, "select * from t left join u on a = b") == "JOIN is not supported"
      assert reason(parser, "select * from t union select * from u") == "UNION is not supported"
    end

    test "errors point at the offending token", %{parser: parser} do
      assert %SyntaxError{line: 3, column: 10, reason: "expected an expression, got '='"} =
               error(parser, "select a\nfrom t\nwhere a ==  1")

      assert %SyntaxError{
               line: 1,
               column: 23,
               reason: "expected an expression, got the end of the statement"
             } =
               error(parser, "select a from t where ")
    end

    test "long strings are truncated in messages", %{parser: parser} do
      assert reason(parser, "select * from t limit '#{String.duplicate("x", 100)}'") =~
               "the string 'xxxxxxxxxxxxxxxxxxxx...'"
    end

    test "parse! raises the error", %{parser: parser} do
      assert_raise SyntaxError, ~r/line 1, column 1: expected SELECT/, fn ->
        parser.parse!("selec * from t")
      end
    end
  end
end
