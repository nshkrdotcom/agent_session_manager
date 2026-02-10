defmodule AgentSessionManager.Adapters.EctoSessionStore.Migration do
  @moduledoc """
  Provides migration functions for the EctoSessionStore adapter.

  This module can be called from your application's migration files
  to create or drop the required tables.

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
  end

  @doc """
  Drops all tables created by `up/0`.
  """
  def down do
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
    end

    create(index(:asm_sessions, [:status]))
    create(index(:asm_sessions, [:agent_id]))
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
    end

    create(index(:asm_runs, [:session_id, :status]))
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
    end

    create(unique_index(:asm_events, [:session_id, :sequence_number]))
    create(index(:asm_events, [:session_id, :type]))
    create(index(:asm_events, [:session_id, :run_id]))
  end

  defp create_session_sequences_table do
    create table(:asm_session_sequences, primary_key: false) do
      add(:session_id, :string, primary_key: true)
      add(:last_sequence, :integer, null: false, default: 0)
    end
  end
end
