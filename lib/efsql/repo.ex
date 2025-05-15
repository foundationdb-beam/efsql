defmodule Efsql.Repo do
  use Ecto.Repo, otp_app: :efsql, adapter: Ecto.Adapters.FoundationDB
  use EctoFoundationDB.Migrator
  def migrations(), do: []
end
