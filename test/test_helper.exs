# Use EfsqlTest.Repo to write data to teh FDB sandbox
Application.put_env(:efsql, EfsqlTest.Repo,
  open_db: &EctoFoundationDB.Sandbox.open_db/1,
  storage_id: EfsqlTest
)

# Use Efsql.Repo to read data from the sandbox without knowing the Ecto.Schema
Application.put_env(:efsql, Efsql.Repo,
  open_db: fn _ -> EctoFoundationDB.Sandbox.open_db(EfsqlTest.Repo) end,
  storage_id: EfsqlTest
)

{:ok, _} = EfsqlTest.Repo.start_link()

ExUnit.start()
