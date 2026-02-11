defmodule AgentSessionManager.OptionalDependency do
  @moduledoc false

  alias AgentSessionManager.Core.Error

  @spec error(atom(), module(), atom()) :: Error.t()
  def error(dependency, module, operation) when is_atom(dependency) and is_atom(operation) do
    Error.new(
      :dependency_not_available,
      "Optional dependency #{inspect(dependency)} is required for #{inspect(module)}",
      details: %{
        dependency: dependency,
        module: inspect(module),
        operation: operation
      }
    )
  end
end
