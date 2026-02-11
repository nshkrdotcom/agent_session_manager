if Code.ensure_loaded?(Ash.Resource) and Code.ensure_loaded?(AshPostgres.DataLayer) do
  defmodule AgentSessionManager.Ash.ResourcesTest do
    use ExUnit.Case, async: true

    alias AgentSessionManager.Ash.Resources

    @resources [
      Resources.Session,
      Resources.Run,
      Resources.Event,
      Resources.SessionSequence,
      Resources.Artifact
    ]

    test "resources compile as Ash resources" do
      Enum.each(@resources, fn resource ->
        assert Ash.Resource.Info.resource?(resource)
      end)
    end

    test "table names are correct" do
      assert AshPostgres.DataLayer.Info.table(Resources.Session) == "asm_sessions"
      assert AshPostgres.DataLayer.Info.table(Resources.Run) == "asm_runs"
      assert AshPostgres.DataLayer.Info.table(Resources.Event) == "asm_events"

      assert AshPostgres.DataLayer.Info.table(Resources.SessionSequence) ==
               "asm_session_sequences"

      assert AshPostgres.DataLayer.Info.table(Resources.Artifact) == "asm_artifacts"
    end

    test "core attributes exist" do
      assert Ash.Resource.Info.attribute(Resources.Session, :id)
      assert Ash.Resource.Info.attribute(Resources.Run, :id)
      assert Ash.Resource.Info.attribute(Resources.Event, :sequence_number)
      assert Ash.Resource.Info.attribute(Resources.SessionSequence, :last_sequence)
      assert Ash.Resource.Info.attribute(Resources.Artifact, :key)
    end

    test "required identities exist" do
      assert Ash.Resource.Info.identity(Resources.Event, :session_sequence)
      assert Ash.Resource.Info.identity(Resources.Artifact, :key)
      assert Ash.Resource.Info.identity(Resources.SessionSequence, :session_id)
    end

    test "custom actions are present" do
      assert Ash.Resource.Info.action(Resources.Session, :upsert, :create)
      assert Ash.Resource.Info.action(Resources.Run, :upsert, :create)
      assert Ash.Resource.Info.action(Resources.Event, :append_with_sequence, :create)
      assert Ash.Resource.Info.action(Resources.SessionSequence, :upsert, :create)
    end
  end
end
