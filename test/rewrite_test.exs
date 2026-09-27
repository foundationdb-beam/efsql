defmodule Efsql.RewriteTest do
  use ExUnit.Case, async: true

  alias Efsql.Logical
  alias Efsql.Rewrite

  defp normalize(predicates) do
    %Logical.Select{predicates: normalized} =
      Rewrite.normalize(%Logical.Select{predicates: predicates})

    normalized
  end

  describe "range merging" do
    test "lower and upper bound on the same field merge" do
      assert [{:range, :name, {:>=, "A"}, {:<=, "C"}}] =
               normalize([{:cmp, :>=, :name, "A"}, {:cmp, :<=, :name, "C"}])

      assert [{:range, :_, {:>, "1"}, {:<, "3"}}] =
               normalize([{:cmp, :>, :_, "1"}, {:cmp, :<, :_, "3"}])
    end

    test "bounds merge across an unrelated condition" do
      assert [
               {:range, :name, {:>=, "A"}, {:<=, "C"}},
               {:cmp, :==, :notes, "x"}
             ] =
               normalize([
                 {:cmp, :>=, :name, "A"},
                 {:cmp, :==, :notes, "x"},
                 {:cmp, :<=, :name, "C"}
               ])
    end

    test "one-sided bounds stay comparisons" do
      assert [{:cmp, :>, :name, "A"}] = normalize([{:cmp, :>, :name, "A"}])
    end

    test "same-direction bounds do not merge" do
      assert [{:cmp, :>, :name, "A"}, {:cmp, :>=, :name, "B"}] =
               normalize([{:cmp, :>, :name, "A"}, {:cmp, :>=, :name, "B"}])
    end
  end

  describe "like prefix rewriting" do
    test "pure prefix pattern becomes a range" do
      assert [{:range, :name, {:>=, "Al"}, {:<, "Am"}}] = normalize([{:like, :name, "Al%"}])
    end

    test "mid-pattern wildcard keeps the like as well" do
      assert [{:range, :name, {:>=, "Al"}, {:<, "Am"}}, {:like, :name, "Al_ce"}] =
               normalize([{:like, :name, "Al_ce"}])
    end

    test "no literal prefix stays a like" do
      assert [{:like, :name, "%ce"}] = normalize([{:like, :name, "%ce"}])
    end

    test "not like is untouched" do
      assert [{:not_like, :name, "Al%"}] = normalize([{:not_like, :name, "Al%"}])
    end

    test "prefix ending in 0xff gets an open upper bound" do
      assert [{:cmp, :>=, :name, <<0xFF>>}] = normalize([{:like, :name, <<0xFF, ?%>>}])
    end
  end

  describe "in singleton" do
    test "single-value in becomes equality" do
      assert [{:cmp, :==, :name, "a"}] = normalize([{:in, :name, ["a"]}])
    end

    test "multi-value in is untouched" do
      assert [{:in, :name, ["a", "b"]}] = normalize([{:in, :name, ["a", "b"]}])
    end

    test "single-value not in becomes an inequality" do
      assert [{:cmp, :!=, :name, "a"}] = normalize([{:not_in, :name, ["a"]}])
      assert [{:not_in, :name, ["a", "b"]}] = normalize([{:not_in, :name, ["a", "b"]}])
    end

    test "ilike is not a key range, whatever its prefix" do
      assert [{:ilike, :name, "Al%"}] = normalize([{:ilike, :name, "Al%"}])
    end
  end

  test "Predicate.take_first takes the first match out, keeping the rest in order" do
    preds = [{:is_null, :a}, {:cmp, :>, :b, 1}, {:cmp, :>, :c, 2}]
    gt? = &match?({:cmp, :>, _, _}, &1)

    assert Efsql.Predicate.take_first(preds, gt?) ==
             {{:cmp, :>, :b, 1}, [{:is_null, :a}, {:cmp, :>, :c, 2}]}

    assert Efsql.Predicate.take_first(preds, fn _ -> false end) == {nil, preds}
  end
end
