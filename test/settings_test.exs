defmodule Efsql.SettingsTest do
  use ExUnit.Case, async: true

  alias Efsql.Settings

  test "defaults" do
    assert %Settings{limit: 15, tenant_batch: nil} = %Settings{}
    assert Settings.query_options(%Settings{}) == []
  end

  test "limit takes a positive integer" do
    assert {:ok, %Settings{limit: 20}, "limit set to 20"} = Settings.set(%Settings{}, "limit 20")
    assert {:ok, %Settings{limit: 3}, _} = Settings.set(%Settings{}, "  limit   3 ")

    for bad <- ["limit 0", "limit -1", "limit x", "limit 2.5", "limit"] do
      assert {:error, "usage: " <> _} = Settings.set(%Settings{}, bad), bad
    end
  end

  test "tenant_batch takes a positive integer or off, and becomes a query option" do
    assert {:ok, settings, "tenant_batch set to 25"} =
             Settings.set(%Settings{}, "tenant_batch 25")

    assert Settings.query_options(settings) == [tenant_batch: 25]

    assert {:ok, settings, _} = Settings.set(settings, "tenant_batch off")
    assert settings.tenant_batch == nil
    assert Settings.query_options(settings) == []

    assert {:error, "usage: \\set tenant_batch N|off"} =
             Settings.set(%Settings{}, "tenant_batch 0")
  end

  test "an unknown setting says what there is" do
    assert {:error, message} = Settings.set(%Settings{}, "colour blue")
    assert message =~ "\\set limit N"
    assert message =~ "\\set tenant_batch N|off"
  end

  test "describe shows the current values" do
    assert [{"\\set limit N", limit}, {"\\set tenant_batch N|off", batch}] =
             Settings.describe(%Settings{limit: 7, tenant_batch: 4})

    assert limit =~ "(7)"
    assert batch =~ "(4)"
  end
end
