if Code.ensure_loaded?(Ecto.Migration) do
  defmodule AgentSessionManager.Adapters.EctoSessionStore.MigrationV3 do
    @moduledoc """
    Migration V3: Adds database-level foreign keys where supported.

    PostgreSQL receives FK constraints for session/run/event/artifact/sequence tables.
    SQLite leaves this migration as a no-op because adding FKs to existing tables
    requires full table rebuilds.
    """

    use Ecto.Migration

    @doc """
    Adds FK constraints on PostgreSQL; no-op on SQLite and other adapters.
    """
    def up do
      case repo().__adapter__() do
        Ecto.Adapters.Postgres -> add_postgres_foreign_keys()
        _ -> :ok
      end
    end

    @doc """
    Drops FK constraints on PostgreSQL; no-op on SQLite and other adapters.
    """
    def down do
      case repo().__adapter__() do
        Ecto.Adapters.Postgres -> drop_postgres_foreign_keys()
        _ -> :ok
      end
    end

    defp add_postgres_foreign_keys do
      execute("""
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'asm_runs_session_id_fkey') THEN
          ALTER TABLE asm_runs
          ADD CONSTRAINT asm_runs_session_id_fkey
          FOREIGN KEY (session_id) REFERENCES asm_sessions(id) ON DELETE CASCADE;
        END IF;
      END
      $$;
      """)

      execute("""
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'asm_events_session_id_fkey') THEN
          ALTER TABLE asm_events
          ADD CONSTRAINT asm_events_session_id_fkey
          FOREIGN KEY (session_id) REFERENCES asm_sessions(id) ON DELETE CASCADE;
        END IF;
      END
      $$;
      """)

      execute("""
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'asm_events_run_id_fkey') THEN
          ALTER TABLE asm_events
          ADD CONSTRAINT asm_events_run_id_fkey
          FOREIGN KEY (run_id) REFERENCES asm_runs(id) ON DELETE CASCADE;
        END IF;
      END
      $$;
      """)

      execute("""
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'asm_artifacts_session_id_fkey') THEN
          ALTER TABLE asm_artifacts
          ADD CONSTRAINT asm_artifacts_session_id_fkey
          FOREIGN KEY (session_id) REFERENCES asm_sessions(id) ON DELETE CASCADE;
        END IF;
      END
      $$;
      """)

      execute("""
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'asm_artifacts_run_id_fkey') THEN
          ALTER TABLE asm_artifacts
          ADD CONSTRAINT asm_artifacts_run_id_fkey
          FOREIGN KEY (run_id) REFERENCES asm_runs(id) ON DELETE CASCADE;
        END IF;
      END
      $$;
      """)

      execute("""
      DO $$
      BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'asm_session_sequences_session_id_fkey') THEN
          ALTER TABLE asm_session_sequences
          ADD CONSTRAINT asm_session_sequences_session_id_fkey
          FOREIGN KEY (session_id) REFERENCES asm_sessions(id) ON DELETE CASCADE;
        END IF;
      END
      $$;
      """)
    end

    defp drop_postgres_foreign_keys do
      execute(
        "ALTER TABLE asm_session_sequences DROP CONSTRAINT IF EXISTS asm_session_sequences_session_id_fkey;"
      )

      execute("ALTER TABLE asm_artifacts DROP CONSTRAINT IF EXISTS asm_artifacts_run_id_fkey;")

      execute(
        "ALTER TABLE asm_artifacts DROP CONSTRAINT IF EXISTS asm_artifacts_session_id_fkey;"
      )

      execute("ALTER TABLE asm_events DROP CONSTRAINT IF EXISTS asm_events_run_id_fkey;")
      execute("ALTER TABLE asm_events DROP CONSTRAINT IF EXISTS asm_events_session_id_fkey;")
      execute("ALTER TABLE asm_runs DROP CONSTRAINT IF EXISTS asm_runs_session_id_fkey;")
    end
  end
else
  defmodule AgentSessionManager.Adapters.EctoSessionStore.MigrationV3 do
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
