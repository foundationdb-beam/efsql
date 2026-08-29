defmodule Efsql.Tui.EventTest do
  use ExUnit.Case, async: true

  alias Efsql.Tui.Event

  test "printable characters" do
    assert {[{:char, "a"}, {:char, "b"}], ""} = Event.decode("ab")
  end

  test "multibyte utf-8" do
    assert {[{:char, "é"}, {:char, "✓"}], ""} = Event.decode("é✓")
  end

  test "incomplete utf-8 tail is buffered" do
    <<head, _rest::binary>> = "é"
    assert {[], <<^head>>} = Event.decode(<<head>>)
  end

  test "control keys" do
    assert {[{:key, :enter}], ""} = Event.decode("\r")
    assert {[{:key, :tab}], ""} = Event.decode("\t")
    assert {[{:key, :backspace}], ""} = Event.decode("\x7f")
    assert {[{:key, :ctrl_c}], ""} = Event.decode("\x03")
  end

  test "arrow keys" do
    assert {[{:key, :up}, {:key, :down}, {:key, :right}, {:key, :left}], ""} =
             Event.decode("\e[A\e[B\e[C\e[D")
  end

  test "tilde sequences" do
    assert {[{:key, :page_up}, {:key, :page_down}, {:key, :delete}], ""} =
             Event.decode("\e[5~\e[6~\e[3~")
  end

  test "lone escape is buffered, then flushed" do
    assert {[], "\e"} = Event.decode("\e")
    assert [{:key, :esc}] = Event.flush("\e")
  end

  test "escape followed by non-bracket is esc plus char" do
    assert {[{:key, :esc}, {:char, "x"}], ""} = Event.decode("\ex")
  end

  test "partial csi is buffered" do
    assert {[], "\e["} = Event.decode("\e[")
    assert {[], "\e[5"} = Event.decode("\e[5")
  end

  test "unknown csi is skipped" do
    assert {[{:char, "a"}], ""} = Event.decode("\e[15;2Ra")
  end

  test "mixed buffer" do
    assert {[{:char, "h"}, {:key, :up}, {:char, "i"}, {:key, :enter}], ""} =
             Event.decode("h\e[Ai\r")
  end
end
