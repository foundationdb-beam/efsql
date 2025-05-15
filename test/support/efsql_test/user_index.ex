defmodule EfsqlTest.UserIndex do
  @moduledoc false
  alias EfsqlTest.User
  use EctoFoundationDB.Migration

  @impl true
  def change() do
    [create(index(User, [:name]))]
  end
end
