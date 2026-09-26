defmodule Efsql.SQL.LexerTest do
  use ExUnit.Case, async: true

  alias Efsql.SQL.Lexer
  alias Efsql.SQL.SyntaxError

  defp tokens(sql) do
    {:ok, tokens} = Lexer.tokenize(sql)
    tokens |> Enum.map(fn {type, value, _pos} -> {type, value} end) |> Enum.drop(-1)
  end

  defp positions(sql) do
    {:ok, tokens} = Lexer.tokenize(sql)
    Enum.map(tokens, fn {_type, _value, pos} -> pos end)
  end

  defp error(sql) do
    assert {:error, %SyntaxError{} = e} = Lexer.tokenize(sql)
    e
  end

  test "empty and blank input is just end of input" do
    assert {:ok, [{:eof, nil, {1, 1}}]} = Lexer.tokenize("")
    assert {:ok, [{:eof, nil, {2, 3}}]} = Lexer.tokenize(" \n  ")
  end

  describe "words" do
    test "fold to lower case" do
      assert tokens("SELECT Name fRoM") == [word: "select", word: "name", word: "from"]
    end

    test "take underscores, digits and dollars after the first character" do
      assert tokens("_ _id a1 a$b created_at") ==
               [word: "_", word: "_id", word: "a1", word: "a$b", word: "created_at"]
    end

    test "take Unicode letters and marks" do
      assert tokens("café 日本語 Ωmega") == [word: "café", word: "日本語", word: "ωmega"]
    end

    test "keywords are plain words; the parser decides" do
      assert tokens("day at user order") ==
               [word: "day", word: "at", word: "user", word: "order"]
    end
  end

  describe "quoted identifiers" do
    test "keep case and spaces" do
      assert tokens(~s("Mixed Case")) == [quoted: "Mixed Case"]
    end

    test "a doubled quote is a quote" do
      assert tokens(~s("say ""hi""")) == [quoted: ~s(say "hi")]
    end

    test "may span lines and hold keywords" do
      assert tokens(~s("select\nfrom")) == [quoted: "select\nfrom"]
    end

    test "can't be empty" do
      assert %SyntaxError{reason: "zero-length quoted identifier", line: 1, column: 8} =
               error(~s(select ""))
    end

    test "must be closed" do
      assert %SyntaxError{line: 1, column: 8, reason: reason} = error(~s(select "abc))
      assert reason =~ "unterminated identifier"
    end
  end

  describe "strings" do
    test "keep their content verbatim" do
      assert tokens("'Hello, World'") == [string: "Hello, World"]
    end

    test "a doubled quote is a quote" do
      assert tokens("'it''s'") == [string: "it's"]
      assert tokens("''''") == [string: "'"]
      assert tokens("''") == [string: ""]
    end

    test "hide comment and operator characters" do
      assert tokens("'-- not a comment /* nor this */ ; ::'") ==
               [string: "-- not a comment /* nor this */ ; ::"]
    end

    test "may span lines, and positions continue after them" do
      assert tokens("'a\nb' x") == [string: "a\nb", word: "x"]
      assert positions("'a\nb' x") == [{1, 1}, {2, 4}, {2, 5}]
    end

    test "take any Unicode" do
      assert tokens("'naïve ☃ 𝄞'") == [string: "naïve ☃ 𝄞"]
    end

    test "must be closed" do
      e = error("where x = 'abc")
      assert e.reason =~ "unterminated string"
      assert {e.line, e.column} == {1, 11}
    end
  end

  describe "numbers" do
    test "integers" do
      assert tokens("0 42 007 123456789012345678901234567890") ==
               [
                 integer: 0,
                 integer: 42,
                 integer: 7,
                 integer: 123_456_789_012_345_678_901_234_567_890
               ]
    end

    test "floats in every spelling" do
      assert tokens("1.5 .5 1. 1e3 1E3 1.5e-3 2.5E+2") ==
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

    test "are unsigned; a sign is a separate token" do
      assert tokens("-1 +2") == [op: :-, integer: 1, op: :+, integer: 2]
    end

    test "can't run into a word" do
      assert error("123abc").reason =~ "invalid number"
      assert error("1.5.2").reason =~ "invalid number"
    end

    test "out of a double's range" do
      assert error("1e400").reason == "number out of range: 1e400"
      assert tokens("1e-400") == [float: 0.0]
    end

    test "need exponent digits" do
      assert error("1e").reason =~ "exponent has no digits"
      assert error("1e+x").reason =~ "exponent has no digits"
    end
  end

  describe "operators" do
    test "two-character operators win over one-character ones" do
      assert tokens("<> != <= >= ::") == [op: :<>, op: :<>, op: :<=, op: :>=, op: :"::"]
    end

    test "one-character operators" do
      assert tokens("= < > ( ) , . ; * + - / %") ==
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

    test "need no surrounding space" do
      assert tokens("a>=1") == [word: "a", op: :>=, integer: 1]
      assert tokens("'x'::atom") == [string: "x", op: :"::", word: "atom"]
      assert tokens("t.users") == [word: "t", op: :., word: "users"]
    end
  end

  describe "comments and whitespace" do
    test "line comments run to the end of the line" do
      assert tokens("a -- ignored ; 'x'\nb") == [word: "a", word: "b"]
      assert tokens("a --") == [word: "a"]
    end

    test "the end of input after a line comment is positioned after it" do
      assert positions("a -- é\xFFz") == [{1, 1}, {1, 9}]
      assert positions("a --\nb") == [{1, 1}, {2, 1}, {2, 2}]
    end

    test "block comments, which nest" do
      assert tokens("a /* one /* two */ still */ b") == [word: "a", word: "b"]
    end

    test "a block comment can split tokens" do
      assert tokens("a/**/b") == [word: "a", word: "b"]
    end

    test "an unclosed block comment is an error at its start" do
      assert %SyntaxError{line: 2, column: 3} = error("a\n  /* /* */")
    end

    test "tabs, CRLF and Unicode spaces separate tokens" do
      assert tokens("a\tb\r\nc\rd e　f") ==
               [word: "a", word: "b", word: "c", word: "d", word: "e", word: "f"]
    end

    test "a byte-order mark is ignored" do
      assert tokens("﻿select") == [word: "select"]
    end
  end

  describe "positions" do
    test "are line and column of the token's first character" do
      assert positions("select id\nfrom t") == [{1, 1}, {1, 8}, {2, 1}, {2, 6}, {2, 7}]
    end

    test "count characters, not bytes" do
      assert positions("'é' x") == [{1, 1}, {1, 5}, {1, 6}]
    end

    test "CRLF is one line break" do
      assert positions("a\r\nb") == [{1, 1}, {2, 1}, {2, 2}]
    end

    test "comments advance them" do
      assert positions("/* a\nb */ x -- c\ny") == [{2, 6}, {3, 1}, {3, 2}]
    end
  end

  describe "errors" do
    test "an unknown character, with its position" do
      assert %SyntaxError{reason: ~s(unexpected character "@"), line: 2, column: 3} =
               error("a\nb @")
    end

    test "Elixir atom syntax gets a hint" do
      assert error("where x = :active").reason =~ "'name'::atom"
    end

    test "invalid UTF-8" do
      assert error(<<"a ", 0xFF, " b">>).reason =~ "invalid UTF-8"
      assert error(<<"'", 0xC3, "'">>).reason =~ "invalid UTF-8"
    end

    test "format as a message" do
      assert Exception.message(error("@")) ==
               ~s(syntax error at line 1, column 1: unexpected character "@")
    end
  end
end
