defmodule Efsql.Result do
  @moduledoc """
  What a query returns, ready to show: its rows, their columns in order
  (see `Efsql.Render.columns/2`), how many transactions they were read in
  (more than one only for a query across tenants read in batches), the
  plan that produced them, and how long it took.
  """

  alias Efsql.Physical.Plan

  defstruct rows: [], columns: [], transactions: 1, plan: nil, elapsed_ms: 0

  @type t :: %__MODULE__{
          rows: [map()],
          columns: [atom()],
          transactions: pos_integer(),
          plan: Plan.t(),
          elapsed_ms: non_neg_integer()
        }

  @spec new(Plan.t(), [map()], non_neg_integer()) :: t()
  def new(%Plan{} = plan, rows, elapsed_ms \\ 0) do
    %__MODULE__{
      rows: rows,
      columns: Efsql.Render.columns(plan, rows),
      transactions: Efsql.Fanout.transactions(plan),
      plan: plan,
      elapsed_ms: elapsed_ms
    }
  end
end
