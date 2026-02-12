defmodule AgentSessionManager.Examples.PersistenceExamplesAdapterUsageTest do
  use ExUnit.Case, async: true

  @query_examples [
    "examples/persistence_query.exs",
    "examples/persistence_multi_run.exs"
  ]

  test "query examples use QueryAPI port tuple instead of nonexistent start_link/1" do
    Enum.each(@query_examples, fn path ->
      content = File.read!(path)

      refute content =~ "EctoQueryAPI.start_link",
             "#{path} should not call EctoQueryAPI.start_link/1"
    end)
  end

  test "maintenance example uses Maintenance port tuple instead of nonexistent start_link/1" do
    content = File.read!("examples/persistence_maintenance.exs")

    refute content =~ "EctoMaintenance.start_link",
           "examples/persistence_maintenance.exs should not call EctoMaintenance.start_link/1"
  end
end
