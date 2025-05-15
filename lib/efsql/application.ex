defmodule Efsql.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Efsql.Repo
    ]

    opts = [strategy: :one_for_one, name: Efsql.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
