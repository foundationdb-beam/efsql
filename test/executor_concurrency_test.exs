defmodule Efsql.ExecutorConcurrencyTest do
  use ExUnit.Case, async: true

  alias Efsql.Exception.Unsupported
  alias Efsql.Executor

  defp map_concurrently(items, max, fun),
    do: items |> Executor.stream_concurrently(max, fun) |> Enum.to_list()

  test "results come back in order, whatever order the work finishes in" do
    assert map_concurrently([30, 10, 20, 0], 4, fn ms ->
             Process.sleep(ms)
             ms
           end) == [30, 10, 20, 0]
  end

  test "at most max run at once, and more than one does" do
    running = :counters.new(2, [])

    map_concurrently(1..12, 3, fn _ ->
      :counters.add(running, 1, 1)
      now = :counters.get(running, 1)
      if now > :counters.get(running, 2), do: :counters.put(running, 2, now)
      Process.sleep(20)
      :counters.sub(running, 1, 1)
    end)

    assert :counters.get(running, 2) in 2..3
  end

  test "a failure reaches the caller as the original exception" do
    assert_raise Unsupported, "too big", fn ->
      map_concurrently([1, 2, 3], 2, fn
        2 -> raise Unsupported, "too big"
        n -> n
      end)
    end

    assert catch_throw(map_concurrently([1], 2, fn _ -> throw(:stop) end)) == :stop
    assert catch_exit(map_concurrently([1], 2, fn _ -> exit(:gone) end)) == :gone
  end

  test "a failure stops the work not yet done" do
    started = :counters.new(1, [])

    assert_raise Unsupported, fn ->
      map_concurrently(1..50, 2, fn n ->
        :counters.add(started, 1, 1)
        if n == 1, do: raise(Unsupported, "stop"), else: Process.sleep(50)
      end)
    end

    assert :counters.get(started, 1) < 50
  end

  test "with max 1 everything runs in the calling process" do
    me = self()
    assert map_concurrently([1, 2], 1, fn _ -> self() end) == [me, me]
  end

  test "halting the stream stops the work not yet started" do
    started = :counters.new(1, [])

    first =
      1..100
      |> Executor.stream_concurrently(2, fn n ->
        :counters.add(started, 1, 1)
        Process.sleep(5)
        n
      end)
      |> Enum.take(3)

    assert first == [1, 2, 3]
    assert :counters.get(started, 1) < 10

    # one at a time, lazily: nothing past what was taken
    :counters.put(started, 1, 0)

    count = fn n ->
      :counters.add(started, 1, 1)
      n
    end

    assert Enum.take(Executor.stream_concurrently(1..100, 1, count), 2) == [1, 2]
    assert :counters.get(started, 1) == 2
  end
end
