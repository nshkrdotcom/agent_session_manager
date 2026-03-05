defmodule Mix.Tasks.Compile.Boundary do
  @moduledoc false

  use Mix.Task.Compiler

  @recursive true

  @impl Mix.Task.Compiler
  def run(_args) do
    case Boundary.Checker.check_project() do
      {:ok, _result} ->
        {:ok, []}

      {:error, violations} ->
        Enum.each(violations, fn violation ->
          Mix.shell().error(Boundary.Checker.format_violation(violation))
        end)

        {:error, []}
    end
  end
end
