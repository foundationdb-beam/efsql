defmodule Efsql.PipelineTest do
  use ExUnit.Case, async: true

  alias Efsql.Aggregate
  alias Efsql.Executor
  alias Efsql.Pipeline
  alias Efsql.Predicate

  # The operators applied to all the rows at once: what the pipeline must
  # match however the rows are chunked.
  defp reference(ops, rows) do
    Enum.reduce(ops, rows, fn
      {:filter, preds}, rows -> Enum.filter(rows, &Predicate.matches?(&1, preds))
      {:sort, order}, rows -> Executor.sort(rows, order)
      {:limit, n}, rows -> Enum.take(rows, n)
      {:project, fields}, rows -> Enum.map(rows, &Map.take(&1, fields))
      {:aggregate, group_by, aggs}, rows -> Aggregate.run(rows, group_by, aggs)
    end)
  end

  # Feeds chunk by chunk, stopping when the pipeline halts.
  defp streamed(ops, chunks) do
    chunks
    |> Enum.reduce_while(Pipeline.new(ops), &Pipeline.feed(&2, &1))
    |> Pipeline.finish()
  end

  defp random_rows(n) do
    for i <- 1..n//1 do
      %{
        id: i,
        city: Enum.random(["Lima", "Osaka", "Oslo", nil]),
        age: Enum.random([nil, 18, 30, 30, 45, 60]),
        price: Enum.random([nil, 1, 2.5, Decimal.new("3.25")])
      }
    end
  end

  defp random_chunks(rows) do
    Enum.chunk_every(rows, Enum.random(1..max(length(rows), 1)))
  end

  defp random_ops() do
    filter =
      Enum.random([[], [{:filter, [{:cmp, :>=, :age, 30}]}], [{:filter, [{:not_null, :city}]}]])

    order = Enum.random([[asc: :age], [desc: :age, asc: :id], [asc: :city, desc: :id]])
    limit = Enum.random([[], [{:limit, 0}], [{:limit, 1}], [{:limit, 3}], [{:limit, 1000}]])

    case Enum.random(1..3) do
      1 ->
        filter ++
          Enum.random([[], [{:sort, order}]]) ++
          limit ++ Enum.random([[], [{:project, [:id, :age]}]])

      2 ->
        aggs = [{:n, :count, :star}, {:a, :avg, :age}, {:s, :sum, :price}, {:m, :max, :city}]

        filter ++
          [{:aggregate, Enum.random([[], [:city], [:city, :age]]), aggs}] ++
          Enum.random([[], [{:sort, [desc: :n]}]]) ++ limit

      3 ->
        filter ++ [{:sort, order}, {:limit, Enum.random(0..5)}, {:project, [:id]}]
    end
  end

  test "however the rows are chunked, the result is the operators over all of them" do
    for _ <- 1..500 do
      rows = random_rows(Enum.random(0..40))
      ops = random_ops()

      assert streamed(ops, random_chunks(rows)) == reference(ops, rows),
             "ops: #{inspect(ops)}"
    end
  end

  test "a limit halts the feeding once it has its rows" do
    chunks = [[%{id: 1}, %{id: 2}], [%{id: 3}], [%{id: 4}]]
    pipeline = Pipeline.new([{:filter, [{:cmp, :>, :id, 1}]}, {:limit, 2}])

    {:cont, pipeline} = Pipeline.feed(pipeline, Enum.at(chunks, 0))
    {:halt, pipeline} = Pipeline.feed(pipeline, Enum.at(chunks, 1))
    assert Pipeline.finish(pipeline) == [%{id: 2}, %{id: 3}]
  end

  test "a sort a limit cuts keeps only the best rows between chunks" do
    pipeline = Pipeline.new([{:sort, [desc: :n]}, {:limit, 2}])

    pipeline =
      Enum.reduce([[%{n: 1}, %{n: 5}], [%{n: 3}, %{n: 9}], [%{n: 4}]], pipeline, fn chunk, p ->
        {:cont, p} = Pipeline.feed(p, chunk)
        # never more than the limit held
        assert [{{:top, _, 2}, best}] = p.stages
        assert length(best) <= 2
        p
      end)

    assert Pipeline.finish(pipeline) == [%{n: 9}, %{n: 5}]
  end

  test "an aggregate adds each chunk to its running totals" do
    ops = [{:aggregate, [:g], [{:n, :count, :star}, {:t, :sum, :v}, {:a, :avg, :v}]}]
    chunks = [[%{g: 1, v: 2}, %{g: 2, v: 5}], [%{g: 1, v: 4}], [%{g: 1, v: nil}]]

    assert streamed(ops, chunks) == [
             %{g: 1, n: 3, t: 6, a: 3.0},
             %{g: 2, n: 1, t: 5, a: 5.0}
           ]
  end

  test "no chunks at all" do
    assert streamed([{:sort, [asc: :a]}, {:limit, 2}], []) == []
    assert streamed([{:aggregate, [], [{:n, :count, :star}]}], []) == [%{n: 0}]
  end
end
