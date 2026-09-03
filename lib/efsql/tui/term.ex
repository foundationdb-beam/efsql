defmodule Efsql.Tui.Term do
  @moduledoc """
  The tty edge: OTP 28 raw mode via `:shell.start_interactive({:noshell,
  :raw})`, alternate-screen lifecycle, and terminal size. Everything else
  in the TUI is pure; only this module and `Efsql.Tui.Screen` write to the
  terminal.
  """

  def tty?() do
    case :io.getopts(:standard_io) do
      opts when is_list(opts) -> Keyword.get(opts, :terminal, false) == true
      _ -> false
    end
  end

  @doc """
  Switches stdin to raw mode. Fails on a non-tty (`:enotsup`) or when a
  shell is already running in this node (e.g. under `iex`).
  """
  def enter_raw() do
    case :shell.start_interactive({:noshell, :raw}) do
      :ok ->
        :io.setopts(:standard_io, binary: true, encoding: :latin1)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `\e[?1l` puts cursor keys back in normal mode (`\e[A`, not `\eOA`) in
  # case a previous program left application mode on; `Efsql.Tui.Event`
  # decodes both forms, this just keeps the common path common.
  def alt_screen_on() do
    write("\e[?1049h\e[?1l\e[?25l\e[2J\e[H")
  end

  def alt_screen_off() do
    write("\e[0m\e[2J\e[?1049l\e[?25h")
  end

  def size() do
    with {:ok, rows} <- :io.rows(:standard_io),
         {:ok, cols} <- :io.columns(:standard_io) do
      {rows, cols}
    else
      _ -> {24, 80}
    end
  end

  def write(iodata), do: IO.binwrite(:stdio, iodata)
end
