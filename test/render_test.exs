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
end
