if Code.ensure_loaded?(Ecto.Migration) do
  defmodule AgentSessionManager.Adapters.EctoSessionStore.Migration do
    @moduledoc """
    Provides migration functions for the EctoSessionStore adapter.

    This migration is canonical for the unreleased 0.8.0 persistence schema and
    creates all required tables, columns, and indexes in one step.

    ## Usage

    Create a migration in your application:

        defmodule MyApp.Repo.Migrations.AddAgentSessionManager do
          use Ecto.Migration

          def up do
            AgentSessionManager.Adapters.EctoSessionStore.Migration.up()
          end

          def down do
            AgentSessionManager.Adapters.EctoSessionStore.Migration.down()
          end
        end

    """

    use Ecto.Migration

    @doc """
    Creates all tables and indexes required by the EctoSessionStore.
    """
    def up do
      create_sessions_table()
      create_runs_table()
      create_events_table()
      create_session_sequences_table()
      create_artifacts_table()
    end

    @doc """
    Drops all tables created by `up/0`.
    """
    def down do
      drop_if_exists(table(:asm_artifacts))
      drop_if_exists(table(:asm_session_sequences))
      drop_if_exists(table(:asm_events))
      drop_if_exists(table(:asm_runs))
      drop_if_exists(table(:asm_sessions))
    end

    defp create_sessions_table do
      create table(:asm_sessions, primary_key: false) do
        add(:id, :string, primary_key: true)
        add(:agent_id, :string, null: false)
        add(:status, :string, null: false)
        add(:parent_session_id, :string)
        add(:metadata, :map, default: %{})
        add(:context, :map, default: %{})
        add(:tags, {:array, :string}, default: [])
        add(:created_at, :utc_datetime_usec, null: false)
        add(:updated_at, :utc_datetime_usec, null: false)
        add(:deleted_at, :utc_datetime_usec, null: true)
      end

      create(index(:asm_sessions, [:status]))
      create(index(:asm_sessions, [:agent_id]))
      create(index(:asm_sessions, [:created_at]))
      create(index(:asm_sessions, [:deleted_at]))
    end

    defp create_runs_table do
      create table(:asm_runs, primary_key: false) do
        add(:id, :string, primary_key: true)
        add(:session_id, :string, null: false)
        add(:status, :string, null: false)
        add(:input, :map)
        add(:output, :map)
        add(:error, :map)
        add(:metadata, :map, default: %{})
        add(:turn_count, :integer, default: 0)
        add(:token_usage, :map, default: %{})
        add(:started_at, :utc_datetime_usec, null: false)
        add(:ended_at, :utc_datetime_usec)
        add(:provider, :string, null: true)
        add(:provider_metadata, :map, null: false, default: %{})
        add(:cost_usd, :float)
      end

      create(index(:asm_runs, [:session_id, :status]))
      create(index(:asm_runs, [:provider]))
      create(index(:asm_runs, [:started_at]))
    end

    defp create_events_table do
      create table(:asm_events, primary_key: false) do
        add(:id, :string, primary_key: true)
        add(:type, :string, null: false)
        add(:timestamp, :utc_datetime_usec, null: false)
        add(:session_id, :string, null: false)
        add(:run_id, :string)
        add(:sequence_number, :integer, null: false)
        add(:data, :map, default: %{})
        add(:metadata, :map, default: %{})
        add(:schema_version, :integer, null: false, default: 1)
        add(:provider, :string, null: true)
        add(:correlation_id, :string, null: true)
      end

      create(unique_index(:asm_events, [:session_id, :sequence_number]))
      create(index(:asm_events, [:session_id, :type]))
      create(index(:asm_events, [:session_id, :run_id]))
      create(index(:asm_events, [:correlation_id]))
      create(index(:asm_events, [:provider]))
      create(index(:asm_events, [:timestamp]))
    end

    defp create_session_sequences_table do
      create table(:asm_session_sequences, primary_key: false) do
        add(:session_id, :string, primary_key: true)
        add(:last_sequence, :integer, null: false, default: 0)
        add(:updated_at, :utc_datetime_usec, null: true)
      end
    end

    defp create_artifacts_table do
      create table(:asm_artifacts, primary_key: false) do
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

      create(unique_index(:asm_artifacts, [:key]))
      create(index(:asm_artifacts, [:session_id]))
      create(index(:asm_artifacts, [:created_at]))
    end
  end
else
  defmodule AgentSessionManager.Adapters.EctoSessionStore.Migration do
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
