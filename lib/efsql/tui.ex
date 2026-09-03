defmodule Efsql.Tui do
  @moduledoc """
  The impure loop around `Efsql.Tui.App`: reads raw input, decodes it with
  `Efsql.Tui.Event`, feeds messages to the pure `update/2`, runs the
  returned commands (background tasks, quit), and paints frames.

  `run/1` owns the terminal lifecycle: raw mode and the alternate screen
  are restored in an `after` block no matter how the loop ends.
  """

  use GenServer

  alias Efsql.Tui.App
  alias Efsql.Tui.Event
  alias Efsql.Tui.Screen
  alias Efsql.Tui.Term
  alias Efsql.Tui.View

  @esc_timeout_ms 40
  @resize_poll_ms 300

  def run(opts \\ []) do
    case Term.enter_raw() do
      :ok ->
        Term.alt_screen_on()

        try do
          {:ok, pid} = GenServer.start_link(__MODULE__, opts)
          ref = Process.monitor(pid)

          receive do
            {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
          end
        after
          Term.alt_screen_off()
        end

        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(_opts) do
    loop = self()
    spawn_link(fn -> read_input(loop) end)

    cluster_file =
      Application.get_env(:efsql, Efsql.Repo, []) |> Keyword.get(:cluster_file, "default")

    {model, cmds} = App.init(size: Term.size(), cluster_file: cluster_file)
    state = %{model: model, buffer: <<>>, esc_timer: nil, tasks: %{}}

    Process.send_after(self(), :resize_poll, @resize_poll_ms)

    case run_cmds(state, cmds) do
      {:stop, state} -> {:ok, state, {:continue, :quit}}
      state -> {:ok, paint(state)}
    end
  end

  @impl true
  def handle_continue(:quit, state), do: {:stop, :normal, state}

  @impl true
  def handle_info({:input, data}, state) do
    state = cancel_esc_timer(state)
    {events, rest} = Event.decode(state.buffer <> drain_input(data))

    state =
      case rest do
        <<0x1B, _::binary>> ->
          %{state | buffer: rest, esc_timer: Process.send_after(self(), :esc_timeout, @esc_timeout_ms)}

        _ ->
          %{state | buffer: rest}
      end

    dispatch_all(state, events)
  end

  def handle_info(:esc_timeout, state) do
    events = Event.flush(state.buffer)
    dispatch_all(%{state | buffer: <<>>, esc_timer: nil}, events)
  end

  def handle_info(:eof, state), do: {:stop, :normal, state}

  def handle_info(:resize_poll, state) do
    Process.send_after(self(), :resize_poll, @resize_poll_ms)
    size = Term.size()

    if size != state.model.size do
      dispatch_all(state, [{:resize, size}])
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.tasks, ref) do
      {nil, _} ->
        {:noreply, state}

      {tag, tasks} ->
        result =
          case reason do
            {:efsql_task, res} -> res
            other -> {:error, other}
          end

        dispatch_all(%{state | tasks: tasks}, [{:done, tag, result}])
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- dispatch / commands --

  defp dispatch_all(state, events) do
    result =
      Enum.reduce_while(events, state, fn event, state ->
        {model, cmds} = App.update(state.model, event)

        case run_cmds(%{state | model: model}, cmds) do
          {:stop, state} -> {:halt, {:stop, state}}
          state -> {:cont, state}
        end
      end)

    case result do
      {:stop, state} -> {:stop, :normal, state}
      state -> {:noreply, paint(state)}
    end
  end

  defp run_cmds(state, cmds) do
    Enum.reduce_while(cmds, state, fn
      :quit, state ->
        {:halt, {:stop, state}}

      :cancel_tasks, state ->
        {:cont, cancel_tasks(state)}

      {:task, tag, fun}, state ->
        {_pid, ref} =
          spawn_monitor(fn ->
            result =
              try do
                {:ok, fun.()}
              rescue
                e -> {:error, e}
              catch
                kind, reason -> {:error, {kind, reason}}
              end

            exit({:efsql_task, result})
          end)

        {:cont, %{state | tasks: Map.put(state.tasks, ref, tag)}}
    end)
  end

  defp cancel_tasks(state) do
    for {ref, _tag} <- state.tasks do
      Process.demonitor(ref, [:flush])
    end

    %{state | tasks: %{}}
  end

  # Coalesces input that queued while the last frame was painted (a held key,
  # a paste) so one decode and one paint cover all of it. Otherwise each
  # message would get its own frame and the screen would fall further behind
  # the keyboard the longer the key is held, then keep scrolling after release.
  defp drain_input(acc) do
    receive do
      {:input, more} -> drain_input(acc <> more)
    after
      0 -> acc
    end
  end

  defp cancel_esc_timer(%{esc_timer: nil} = state), do: state

  defp cancel_esc_timer(%{esc_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | esc_timer: nil}
  end

  defp paint(state) do
    Screen.paint(View.view(state.model))
    state
  end

  # -- input reader --

  defp read_input(loop) do
    case :io.get_chars(:standard_io, "", 1024) do
      :eof ->
        send(loop, :eof)

      {:error, _reason} ->
        send(loop, :eof)

      data ->
        send(loop, {:input, IO.iodata_to_binary(data)})
        read_input(loop)
    end
  end
end
