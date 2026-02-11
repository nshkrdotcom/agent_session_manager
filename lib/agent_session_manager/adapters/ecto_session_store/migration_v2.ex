if Code.ensure_loaded?(Ecto.Migration) do
  defmodule AgentSessionManager.Adapters.EctoSessionStore.MigrationV2 do
    @moduledoc """
    Migration V2: Adds persistence layer fields for provider identity,
    soft deletes, correlation tracking, and artifact registry.

    ## Changes

    - `asm_sessions`: adds `deleted_at`
    - `asm_runs`: adds `provider`, `provider_metadata`, `cost_usd`
    - `asm_events`: adds `provider`, `correlation_id`
    - `asm_session_sequences`: adds `updated_at`
    - Creates `asm_artifacts` table

    ## Usage

        defmodule MyApp.Repo.Migrations.AgentSessionManagerV2 do
          use Ecto.Migration

          def up do
            AgentSessionManager.Adapters.EctoSessionStore.MigrationV2.up()
          end

          def down do
            AgentSessionManager.Adapters.EctoSessionStore.MigrationV2.down()
          end
        end

    """

    use Ecto.Migration

    @doc """
    Adds new columns, the artifacts table, and new indexes.
    """
    def up do
      alter_sessions()
      alter_runs()
      alter_events()
      alter_session_sequences()
      create_artifacts_table()
      create_new_indexes()
    end

    @doc """
    Reverses the V2 migration.

    Note: SQLite does not support DROP COLUMN. On SQLite, the down
    migration only drops the artifacts table and indexes. The added
    columns remain but are unused (nullable, so harmless).
    """
    def down do
      drop_if_exists(table(:asm_artifacts))
      drop_new_indexes()
    end

    defp alter_sessions do
      alter table(:asm_sessions) do
        add(:deleted_at, :utc_datetime_usec, null: true)
      end
    end

    defp alter_runs do
      alter table(:asm_runs) do
        add(:provider, :string, null: true)
        add(:provider_metadata, :map, null: false, default: %{})
        add_if_not_exists(:cost_usd, :float)
      end
    end

    defp alter_events do
      alter table(:asm_events) do
        add(:provider, :string, null: true)
        add(:correlation_id, :string, null: true)
      end
    end

    defp alter_session_sequences do
      alter table(:asm_session_sequences) do
        add(:updated_at, :utc_datetime_usec, null: true)
      end
    end

    defp create_artifacts_table do
      create_if_not_exists table(:asm_artifacts, primary_key: false) do
        add(:id, :string, primary_key: true)
        add(:session_id, :string, null: true)
        add(:run_id, :string, null: true)
        add(:key, :string, null: false)
        add(:content_type, :string, null: true)
        add(:byte_size, :bigint, null: false)
        add(:checksum_sha256, :string, null: false)
        add(:storage_backend, :string, null: false)
        add(:storage_ref, :string, null: false)
        add(:metadata, :map, null: false, default: %{})
        add(:created_at, :utc_datetime_usec, null: false)
        add(:deleted_at, :utc_datetime_usec, null: true)
      end
    end

    defp create_new_indexes do
      create_if_not_exists(unique_index(:asm_artifacts, [:key]))
      create_if_not_exists(index(:asm_artifacts, [:session_id]))
      create_if_not_exists(index(:asm_artifacts, [:created_at]))
      create_if_not_exists(index(:asm_events, [:correlation_id]))
      create_if_not_exists(index(:asm_events, [:provider]))
      create_if_not_exists(index(:asm_events, [:timestamp]))
      create_if_not_exists(index(:asm_runs, [:provider]))
      create_if_not_exists(index(:asm_runs, [:started_at]))
      create_if_not_exists(index(:asm_sessions, [:created_at]))
      create_if_not_exists(index(:asm_sessions, [:deleted_at]))
    end

    defp drop_new_indexes do
      drop_if_exists(index(:asm_sessions, [:deleted_at]))
      drop_if_exists(index(:asm_sessions, [:created_at]))
      drop_if_exists(index(:asm_runs, [:started_at]))
      drop_if_exists(index(:asm_runs, [:provider]))
      drop_if_exists(index(:asm_events, [:timestamp]))
      drop_if_exists(index(:asm_events, [:provider]))
      drop_if_exists(index(:asm_events, [:correlation_id]))
      drop_if_exists(index(:asm_artifacts, [:created_at]))
      drop_if_exists(index(:asm_artifacts, [:session_id]))
      drop_if_exists(unique_index(:asm_artifacts, [:key]))
    end
  end
else
  defmodule AgentSessionManager.Adapters.EctoSessionStore.MigrationV2 do
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
