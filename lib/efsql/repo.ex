defmodule Efsql.Repo do
  use Ecto.Repo, otp_app: :efsql, adapter: Ecto.Adapters.FoundationDB
  use EctoFoundationDB.Migrator
  # Empty for real databases; the dev sandbox supplies its own demo indexes.
  def migrations(), do: Efsql.DevSandbox.migrations()
end
