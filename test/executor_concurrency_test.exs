defmodule Efsql.ExecutorConcurrencyTest do
  use ExUnit.Case, async: true

  alias Efsql.Exception.Unsupported
  alias Efsql.Executor

  test "results come back in order, whatever order the work finishes in" do
    assert Executor.map_concurrently([30, 10, 20, 0], 4, fn ms ->
             Process.sleep(ms)
             ms
           end) == [30, 10, 20, 0]
  end

  test "at most max run at once, and more than one does" do
    running = :counters.new(2, [])

    Executor.map_concurrently(1..12, 3, fn _ ->
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
      Executor.map_concurrently([1, 2, 3], 2, fn
        2 -> raise Unsupported, "too big"
        n -> n
      end)
    end

    assert catch_throw(Executor.map_concurrently([1], 2, fn _ -> throw(:stop) end)) == :stop
    assert catch_exit(Executor.map_concurrently([1], 2, fn _ -> exit(:gone) end)) == :gone
  end

  test "a failure stops the work not yet done" do
    started = :counters.new(1, [])

    assert_raise Unsupported, fn ->
      Executor.map_concurrently(1..50, 2, fn n ->
        :counters.add(started, 1, 1)
        if n == 1, do: raise(Unsupported, "stop"), else: Process.sleep(50)
      end)
    end

    assert :counters.get(started, 1) < 50
  end

  test "with max 1 everything runs in the calling process" do
    me = self()
    assert Executor.map_concurrently([1, 2], 1, fn _ -> self() end) == [me, me]
  end
end
