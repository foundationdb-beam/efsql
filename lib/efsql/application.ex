defmodule Efsql.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    if Efsql.DevSandbox.enabled?(), do: Efsql.DevSandbox.boot!()

    children = [
      {DynamicSupervisor, name: Efsql.StorageCaches, strategy: :one_for_one},
      Efsql.Repo
    ]

    opts = [strategy: :one_for_one, name: Efsql.Supervisor]
    result = Supervisor.start_link(children, opts)

    if Efsql.DevSandbox.enabled?(), do: Efsql.DevSandbox.seed!()

    result
  end
end
