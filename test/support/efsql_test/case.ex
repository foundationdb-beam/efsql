defmodule EfsqlTest.Case do
  @moduledoc false
  use ExUnit.CaseTemplate
  alias EfsqlTest.Repo
  alias EfsqlTest.User
  alias EctoFoundationDB.Sandbox

  def data() do
    [
      %{id: "0001", name: "Alice", notes: "Lorem ipsum"},
      %{id: "0002", name: "Bob", notes: "foobar"},
      %{id: "0003", name: "Charles"}
    ]
  end

  setup do
    # Use a tenant id that can be given as an unescaped identifier
    tenant_id =
      "t_" <>
        (Ecto.UUID.autogenerate()
         |> String.replace("-", ""))

    tenant = Sandbox.checkout(Repo, tenant_id, [])

    Repo.transaction(
      fn ->
        for x <- data() do
          Repo.insert(struct(User, x))
        end
      end,
      prefix: tenant
    )

    on_exit(fn ->
      Sandbox.checkin(Repo, tenant_id)
    end)

    {:ok, [tenant: tenant, tenant_id: tenant_id]}
  end
end
