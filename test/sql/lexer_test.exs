defmodule Efsql.SQL.LexerTest do
  # Every test runs against both lexers: the hand-written one and the one
  # built on leex. They share a contract, token for token.
  use ExUnit.Case,
    async: true,
    parameterize: [%{lexer: Efsql.SQL.Lexer}, %{lexer: Efsql.SQL.Leex}]

  alias Efsql.SQL.SyntaxError

  defp tokens(lexer, sql) do
    {:ok, tokens} = lexer.tokenize(sql)
    tokens |> Enum.map(fn {type, value, _pos} -> {type, value} end) |> Enum.drop(-1)
  end

  defp positions(lexer, sql) do
    {:ok, tokens} = lexer.tokenize(sql)
    Enum.map(tokens, fn {_type, _value, pos} -> pos end)
  end

  defp error(lexer, sql) do
    assert {:error, %SyntaxError{} = e} = lexer.tokenize(sql)
    e
  end

  test "empty and blank input is just end of input", %{lexer: lexer} do
    assert {:ok, [{:eof, nil, {1, 1}}]} = lexer.tokenize("")
    assert {:ok, [{:eof, nil, {2, 3}}]} = lexer.tokenize(" \n  ")
  end

  describe "words" do
    test "fold to lower case", %{lexer: lexer} do
      assert tokens(lexer, "SELECT Name fRoM") == [word: "select", word: "name", word: "from"]
    end

    test "take underscores, digits and dollars after the first character", %{lexer: lexer} do
      assert tokens(lexer, "_ _id a1 a$b created_at") ==
               [word: "_", word: "_id", word: "a1", word: "a$b", word: "created_at"]
    end

    test "take Unicode letters and marks", %{lexer: lexer} do
      assert tokens(lexer, "café 日本語 Ωmega") == [word: "café", word: "日本語", word: "ωmega"]
    end

    test "keywords are plain words; the parser decides", %{lexer: lexer} do
      assert tokens(lexer, "day at user order") ==
               [word: "day", word: "at", word: "user", word: "order"]
    end
  end

  describe "quoted identifiers" do
    test "keep case and spaces", %{lexer: lexer} do
      assert tokens(lexer, ~s("Mixed Case")) == [quoted: "Mixed Case"]
    end

    test "a doubled quote is a quote", %{lexer: lexer} do
      assert tokens(lexer, ~s("say ""hi""")) == [quoted: ~s(say "hi")]
    end

    test "may span lines and hold keywords", %{lexer: lexer} do
      assert tokens(lexer, ~s("select\nfrom")) == [quoted: "select\nfrom"]
    end

    test "can't be empty", %{lexer: lexer} do
      assert %SyntaxError{reason: "zero-length quoted identifier", line: 1, column: 8} =
               error(lexer, ~s(select ""))
    end

    test "must be closed", %{lexer: lexer} do
      assert %SyntaxError{line: 1, column: 8, reason: reason} = error(lexer, ~s(select "abc))
      assert reason =~ "unterminated identifier"
    end
  end

  describe "strings" do
    test "keep their content verbatim", %{lexer: lexer} do
      assert tokens(lexer, "'Hello, World'") == [string: "Hello, World"]
    end

    test "a doubled quote is a quote", %{lexer: lexer} do
      assert tokens(lexer, "'it''s'") == [string: "it's"]
      assert tokens(lexer, "''''") == [string: "'"]
      assert tokens(lexer, "''") == [string: ""]
    end

    test "hide comment and operator characters", %{lexer: lexer} do
      assert tokens(lexer, "'-- not a comment /* nor this */ ; ::'") ==
               [string: "-- not a comment /* nor this */ ; ::"]
    end

    test "may span lines, and positions continue after them", %{lexer: lexer} do
      assert tokens(lexer, "'a\nb' x") == [string: "a\nb", word: "x"]
      assert positions(lexer, "'a\nb' x") == [{1, 1}, {2, 4}, {2, 5}]
    end

    test "take any Unicode", %{lexer: lexer} do
      assert tokens(lexer, "'naïve ☃ 𝄞'") == [string: "naïve ☃ 𝄞"]
    end

    test "must be closed", %{lexer: lexer} do
      e = error(lexer, "where x = 'abc")
      assert e.reason =~ "unterminated string"
      assert {e.line, e.column} == {1, 11}
    end
  end

  describe "numbers" do
    test "integers", %{lexer: lexer} do
      assert tokens(lexer, "0 42 007 123456789012345678901234567890") ==
               [
                 integer: 0,
                 integer: 42,
                 integer: 7,
                 integer: 123_456_789_012_345_678_901_234_567_890
               ]
    end

    test "floats in every spelling", %{lexer: lexer} do
      assert tokens(lexer, "1.5 .5 1. 1e3 1E3 1.5e-3 2.5E+2") ==
               [
                 float: 1.5,
                 float: 0.5,
                 float: 1.0,
                 float: 1.0e3,
                 float: 1.0e3,
                 float: 1.5e-3,
                 float: 250.0
               ]
    end

    test "are unsigned; a sign is a separate token", %{lexer: lexer} do
      assert tokens(lexer, "-1 +2") == [op: :-, integer: 1, op: :+, integer: 2]
    end

    test "can't run into a word", %{lexer: lexer} do
      assert error(lexer, "123abc").reason =~ "invalid number"
      assert error(lexer, "1.5.2").reason =~ "invalid number"
    end

    test "out of a double's range", %{lexer: lexer} do
      assert error(lexer, "1e400").reason == "number out of range: 1e400"
      assert tokens(lexer, "1e-400") == [float: 0.0]
    end

    test "need exponent digits", %{lexer: lexer} do
      assert error(lexer, "1e").reason =~ "exponent has no digits"
      assert error(lexer, "1e+x").reason =~ "exponent has no digits"
    end
  end

  describe "operators" do
    test "two-character operators win over one-character ones", %{lexer: lexer} do
      assert tokens(lexer, "<> != <= >= ::") == [op: :<>, op: :<>, op: :<=, op: :>=, op: :"::"]
    end

    test "one-character operators", %{lexer: lexer} do
      assert tokens(lexer, "= < > ( ) , . ; * + - / %") ==
               [
                 op: :=,
                 op: :<,
                 op: :>,
                 op: :"(",
                 op: :")",
                 op: :",",
                 op: :.,
                 op: :";",
                 op: :*,
                 op: :+,
                 op: :-,
                 op: :/,
                 op: :%
               ]
    end

    test "need no surrounding space", %{lexer: lexer} do
      assert tokens(lexer, "a>=1") == [word: "a", op: :>=, integer: 1]
      assert tokens(lexer, "'x'::atom") == [string: "x", op: :"::", word: "atom"]
      assert tokens(lexer, "t.users") == [word: "t", op: :., word: "users"]
    end
  end

  describe "comments and whitespace" do
    test "line comments run to the end of the line", %{lexer: lexer} do
      assert tokens(lexer, "a -- ignored ; 'x'\nb") == [word: "a", word: "b"]
      assert tokens(lexer, "a --") == [word: "a"]
    end

    test "the end of input after a line comment is positioned after it", %{lexer: lexer} do
      assert positions(lexer, "a -- é\xFFz") == [{1, 1}, {1, 9}]
      assert positions(lexer, "a --\nb") == [{1, 1}, {2, 1}, {2, 2}]
    end

    test "block comments, which nest", %{lexer: lexer} do
      assert tokens(lexer, "a /* one /* two */ still */ b") == [word: "a", word: "b"]
    end

    test "a block comment can split tokens", %{lexer: lexer} do
      assert tokens(lexer, "a/**/b") == [word: "a", word: "b"]
    end

    test "an unclosed block comment is an error at its start", %{lexer: lexer} do
      assert %SyntaxError{line: 2, column: 3} = error(lexer, "a\n  /* /* */")
    end

    test "tabs, CRLF and Unicode spaces separate tokens", %{lexer: lexer} do
      assert tokens(lexer, "a\tb\r\nc\rd e　f") ==
               [word: "a", word: "b", word: "c", word: "d", word: "e", word: "f"]
    end

    test "a byte-order mark is ignored", %{lexer: lexer} do
      assert tokens(lexer, "﻿select") == [word: "select"]
    end
  end

  describe "positions" do
    test "are line and column of the token's first character", %{lexer: lexer} do
      assert positions(lexer, "select id\nfrom t") == [{1, 1}, {1, 8}, {2, 1}, {2, 6}, {2, 7}]
    end

    test "count characters, not bytes", %{lexer: lexer} do
      assert positions(lexer, "'é' x") == [{1, 1}, {1, 5}, {1, 6}]
    end

    test "CRLF is one line break", %{lexer: lexer} do
      assert positions(lexer, "a\r\nb") == [{1, 1}, {2, 1}, {2, 2}]
    end

    test "comments advance them", %{lexer: lexer} do
      assert positions(lexer, "/* a\nb */ x -- c\ny") == [{2, 6}, {3, 1}, {3, 2}]
    end
  end

  describe "errors" do
    test "an unknown character, with its position", %{lexer: lexer} do
      assert %SyntaxError{reason: ~s(unexpected character "@"), line: 2, column: 3} =
               error(lexer, "a\nb @")
    end

    test "Elixir atom syntax gets a hint", %{lexer: lexer} do
      assert error(lexer, "where x = :active").reason =~ "'name'::atom"
    end

    test "invalid UTF-8", %{lexer: lexer} do
      assert error(lexer, <<"a ", 0xFF, " b">>).reason =~ "invalid UTF-8"
      assert error(lexer, <<"'", 0xC3, "'">>).reason =~ "invalid UTF-8"
    end

    test "format as a message", %{lexer: lexer} do
      assert Exception.message(error(lexer, "@")) ==
               ~s(syntax error at line 1, column 1: unexpected character "@")
    end
  end
end
