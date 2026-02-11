defmodule AgentSessionManager.OptionalDependencyTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.OptionalDependency

  test "returns dependency_not_available error with structured details" do
    error =
      OptionalDependency.error(
        :ecto_sql,
        AgentSessionManager.Adapters.EctoSessionStore,
        :start_link
      )

    assert %Error{code: :dependency_not_available} = error
    assert error.details.dependency == :ecto_sql
    assert error.details.operation == :start_link
    assert error.details.module == "AgentSessionManager.Adapters.EctoSessionStore"
  end
end
