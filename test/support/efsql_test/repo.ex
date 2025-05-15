defmodule EfsqlTest.Repo do
  use Ecto.Repo, otp_app: :efsql, adapter: Ecto.Adapters.FoundationDB

  use EctoFoundationDB.Migrator

  @impl true
  def migrations() do
    [
      {0, EfsqlTest.UserIndex}
    ]
  end
end
