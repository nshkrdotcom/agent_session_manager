if Code.ensure_loaded?(Ecto.Migration) do
  defmodule AgentSessionManager.Adapters.EctoSessionStore.MigrationV4 do
    @moduledoc """
    Migration V4: Adds cost_usd column to asm_runs table.
    """

    use Ecto.Migration

    def up do
      alter table(:asm_runs) do
        add_if_not_exists(:cost_usd, :float)
      end
    end

    def down do
      alter table(:asm_runs) do
        remove_if_exists(:cost_usd, :float)
      end
    end
  end
else
  defmodule AgentSessionManager.Adapters.EctoSessionStore.MigrationV4 do
    @moduledoc """
    Fallback migration module used when optional Ecto dependencies are not installed.
    """

    alias AgentSessionManager.OptionalDependency

    @doc false
    def up, do: raise(OptionalDependency.error(:ecto_sql, __MODULE__, :up))

    @doc false
    def down, do: raise(OptionalDependency.error(:ecto_sql, __MODULE__, :down))
  end
end
