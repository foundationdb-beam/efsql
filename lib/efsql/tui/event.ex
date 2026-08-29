defmodule Efsql.Tui.Event do
  @moduledoc """
  Decodes raw terminal bytes into key events.

  `decode/1` consumes as much of the buffer as possible and returns
  `{events, rest}`; `rest` is a partial escape or UTF-8 sequence to prepend
  to the next read. A buffer that is exactly `"\\e"` is ambiguous (lone Esc
  vs. sequence prefix) — the caller flushes it with `flush/1` after a short
  timeout.

  Events: `{:char, grapheme}` and `{:key, name}` with names
  `:enter :tab :shift_tab :backspace :delete :esc :up :down :left :right
  :home :end :page_up :page_down :ctrl_a :ctrl_c :ctrl_d :ctrl_e :ctrl_k
  :ctrl_l :ctrl_u`.
  """

  def decode(buffer), do: decode(buffer, [])

  defp decode(<<>>, acc), do: {Enum.reverse(acc), <<>>}

  defp decode(<<0x1B>>, acc), do: {Enum.reverse(acc), <<0x1B>>}
  defp decode(<<0x1B, ?[>>, acc), do: {Enum.reverse(acc), <<0x1B, ?[>>}

  defp decode(<<0x1B, ?[, rest::binary>> = buffer, acc) do
    case csi(rest) do
      {event, rest2} -> decode(rest2, [event | acc])
      :partial -> {Enum.reverse(acc), buffer}
      :unknown -> decode(skip_csi(rest), acc)
    end
  end

  # Esc followed by anything other than '[' is a lone Esc press
  defp decode(<<0x1B, rest::binary>>, acc), do: decode(rest, [{:key, :esc} | acc])

  defp decode(<<b, rest::binary>>, acc) when b in [?\r, ?\n], do: decode(rest, [{:key, :enter} | acc])
  defp decode(<<?\t, rest::binary>>, acc), do: decode(rest, [{:key, :tab} | acc])
  defp decode(<<0x7F, rest::binary>>, acc), do: decode(rest, [{:key, :backspace} | acc])
  defp decode(<<0x08, rest::binary>>, acc), do: decode(rest, [{:key, :backspace} | acc])
  defp decode(<<0x01, rest::binary>>, acc), do: decode(rest, [{:key, :ctrl_a} | acc])
  defp decode(<<0x03, rest::binary>>, acc), do: decode(rest, [{:key, :ctrl_c} | acc])
  defp decode(<<0x04, rest::binary>>, acc), do: decode(rest, [{:key, :ctrl_d} | acc])
  defp decode(<<0x05, rest::binary>>, acc), do: decode(rest, [{:key, :ctrl_e} | acc])
  defp decode(<<0x0B, rest::binary>>, acc), do: decode(rest, [{:key, :ctrl_k} | acc])
  defp decode(<<0x0C, rest::binary>>, acc), do: decode(rest, [{:key, :ctrl_l} | acc])
  defp decode(<<0x15, rest::binary>>, acc), do: decode(rest, [{:key, :ctrl_u} | acc])

  # other control bytes: ignore
  defp decode(<<b, rest::binary>>, acc) when b < 0x20, do: decode(rest, acc)

  defp decode(buffer, acc) do
    case String.next_grapheme(buffer) do
      {grapheme, rest} ->
        if String.valid?(grapheme) do
          decode(rest, [{:char, grapheme} | acc])
        else
          # invalid or incomplete UTF-8; if it is the tail of the buffer it
          # may complete on the next read
          if rest == <<>> and byte_size(buffer) < 4 do
            {Enum.reverse(acc), buffer}
          else
            decode(rest, acc)
          end
        end

      nil ->
        {Enum.reverse(acc), <<>>}
    end
  end

  @doc "Resolves a pending ambiguous buffer after the Esc timeout."
  def flush(<<0x1B, _::binary>>), do: [{:key, :esc}]
  def flush(_), do: []

  defp csi(<<?A, rest::binary>>), do: {{:key, :up}, rest}
  defp csi(<<?B, rest::binary>>), do: {{:key, :down}, rest}
  defp csi(<<?C, rest::binary>>), do: {{:key, :right}, rest}
  defp csi(<<?D, rest::binary>>), do: {{:key, :left}, rest}
  defp csi(<<?H, rest::binary>>), do: {{:key, :home}, rest}
  defp csi(<<?F, rest::binary>>), do: {{:key, :end}, rest}
  defp csi(<<?Z, rest::binary>>), do: {{:key, :shift_tab}, rest}
  defp csi(<<?1, ?~, rest::binary>>), do: {{:key, :home}, rest}
  defp csi(<<?3, ?~, rest::binary>>), do: {{:key, :delete}, rest}
  defp csi(<<?4, ?~, rest::binary>>), do: {{:key, :end}, rest}
  defp csi(<<?5, ?~, rest::binary>>), do: {{:key, :page_up}, rest}
  defp csi(<<?6, ?~, rest::binary>>), do: {{:key, :page_down}, rest}
  defp csi(<<>>), do: :partial
  defp csi(<<b>>) when b in ?0..?9 or b == ?;, do: :partial
  defp csi(_), do: :unknown

  # Skip an unrecognized CSI sequence: parameter bytes then one final byte.
  defp skip_csi(<<b, rest::binary>>) when b in ?0..?9 or b in [?;, ?<, ?=, ??, ?>], do: skip_csi(rest)
  defp skip_csi(<<_final, rest::binary>>), do: rest
  defp skip_csi(<<>>), do: <<>>
end
