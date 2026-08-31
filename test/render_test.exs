defmodule Efsql.RenderTest do
  use ExUnit.Case, async: true

  alias Efsql.Render

  test "nil renders as nil" do
    assert Render.cell(nil) == "nil"
  end

  test "printable strings render bare" do
    assert Render.cell("hello") == "hello"
  end

  test "non-printable binaries render as sized hex" do
    assert Render.cell(<<0, 255, 1>>) == "<<0x00ff01>> (3 bytes)"
  end

  test "versionstamps render via to_integer" do
    vs = EctoFoundationDB.Versionstamp.from_integer(42)
    assert Render.cell(vs) == "#Versionstamp<42>"
  end

  test "cells truncate" do
    assert Render.cell(String.duplicate("x", 50), 10) == "xxxxxxxxx…"
  end

  test "maps and lists inspect" do
    assert Render.cell(%{a: 1}) == "%{a: 1}"
    assert Render.full([1, 2, 3]) == "[1, 2, 3]"
  end

  test "type_of" do
    assert Render.type_of(nil) == :null
    assert Render.type_of("s") == :string
    assert Render.type_of(<<0, 1>>) == :binary
    assert Render.type_of(1) == :integer
    assert Render.type_of(1.5) == :float
    assert Render.type_of(true) == :boolean
    assert Render.type_of(EctoFoundationDB.Versionstamp.from_integer(1)) == :versionstamp
    assert Render.type_of(~N[2026-01-01 00:00:00]) == :naive_datetime
    assert Render.type_of(%{}) == :map
  end

  test "structs are named after their module" do
    assert Render.type_of(URI.parse("https://example.com")) == :URI
    assert Render.type_of(MapSet.new([1])) == :MapSet
  end

  test "cells collapse newlines and tabs so they stay one line" do
    assert Render.cell("a\nb\tc", 40) == "a b c"
    refute Render.cell("one\ntwo\nthree", 40) =~ "\n"
  end

  describe "wrap" do
    test "short text is one line" do
      assert Render.wrap("hello", 20) == ["hello"]
    end

    test "wraps on spaces" do
      assert Render.wrap("the quick brown fox jumps", 10) == ["the quick", "brown fox", "jumps"]
    end

    test "hard-breaks a word longer than the width" do
      assert Render.wrap(String.duplicate("x", 25), 10) == [
               "xxxxxxxxxx",
               "xxxxxxxxxx",
               "xxxxx"
             ]
    end

    test "existing newlines are preserved" do
      assert Render.wrap("one\ntwo", 20) == ["one", "two"]
      assert Render.wrap("a\n\nb", 20) == ["a", "", "b"]
    end

    test "no line exceeds the width" do
      text = "a very long sentence with supercalifragilisticexpialidocious in it"
      for line <- Render.wrap(text, 12), do: assert(String.length(line) <= 12)
    end

    test "wrapping is multibyte-safe" do
      lines = Render.wrap(String.duplicate("é", 25), 10)
      assert Enum.all?(lines, &(String.length(&1) <= 10))
      assert Enum.join(lines) == String.duplicate("é", 25)
    end

    test "nothing is lost" do
      text = String.duplicate("word ", 20) |> String.trim()
      assert Render.wrap(text, 13) |> Enum.join(" ") == text
    end
  end

  test "structs render with their name, elided in cells and full in the inspector" do
    uri = URI.parse("https://example.com/a?b=1")
    assert Render.cell(uri, 30) |> String.starts_with?("%URI{")
    assert String.length(Render.cell(uri, 30)) <= 30
    assert Render.full(uri) =~ "scheme:"
  end
end
