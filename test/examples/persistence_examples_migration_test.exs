defmodule AgentSessionManager.Examples.PersistenceExamplesMigrationTest do
  use ExUnit.Case, async: true

  @examples [
    "examples/sqlite_session_store_live.exs",
    "examples/ecto_session_store_live.exs",
    "examples/composite_store_live.exs",
    "examples/persistence_query.exs",
    "examples/persistence_maintenance.exs",
    "examples/persistence_multi_run.exs",
    "examples/persistence_live.exs",
    "examples/ash_session_store.exs"
  ]

  test "persistence examples use only consolidated Migration module" do
    Enum.each(@examples, fn path ->
      content = File.read!(path)
      refute content =~ "MigrationV2", "#{path} still references MigrationV2"
      refute content =~ "MigrationV3", "#{path} still references MigrationV3"
      refute content =~ "MigrationV4", "#{path} still references MigrationV4"
      assert content =~ "Migration", "#{path} should reference consolidated Migration"
    end)
  end
end
