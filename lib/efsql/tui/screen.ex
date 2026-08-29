defmodule Efsql.Tui.Screen do
  @moduledoc """
  Paints a frame: absolute-positions each line, clears as it goes, and
  places or hides the terminal cursor. One write per frame, from the one
  process that owns the terminal.
  """

  alias Efsql.Tui.Term

  def paint({lines, cursor}) do
    body =
      lines
      |> Enum.with_index(1)
      |> Enum.map(fn {line, row} -> ["\e[", Integer.to_string(row), ";1H\e[2K", line] end)

    tail =
      case cursor do
        nil -> ["\e[?25l"]
        {row, col} -> ["\e[", Integer.to_string(row), ";", Integer.to_string(col), "H\e[?25h"]
      end

    Term.write(IO.iodata_to_binary([["\e[?25l"], body, tail]))
  end
end
