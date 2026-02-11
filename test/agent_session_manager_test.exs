defmodule AgentSessionManagerTest do
  @moduledoc """
  Tests for the main AgentSessionManager module.

  Uses Supertester for robust async testing and process isolation.
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.{Capability, Error, Event, Manifest, Run, Session}

  describe "AgentSessionManager convenience functions" do
    test "new_session/1 delegates to Session.new/1" do
      {:ok, session} = AgentSessionManager.new_session(%{agent_id: "test-agent"})
      assert session.agent_id == "test-agent"
      assert %Session{} = session
    end

    test "new_run/1 delegates to Run.new/1" do
      {:ok, run} = AgentSessionManager.new_run(%{session_id: "test-session"})
      assert run.session_id == "test-session"
      assert %Run{} = run
    end

    test "new_event/1 delegates to Event.new/1" do
      {:ok, event} =
        AgentSessionManager.new_event(%{
          type: :session_created,
          session_id: "test-session"
        })

      assert event.type == :session_created
      assert %Event{} = event
    end

    test "new_capability/1 delegates to Capability.new/1" do
      {:ok, capability} =
        AgentSessionManager.new_capability(%{
          name: "test-cap",
          type: :tool
        })

      assert capability.name == "test-cap"
      assert %Capability{} = capability
    end

    test "new_manifest/1 delegates to Manifest.new/1" do
      {:ok, manifest} =
        AgentSessionManager.new_manifest(%{
          name: "test-agent",
          version: "1.0.0"
        })

      assert manifest.name == "test-agent"
      assert %Manifest{} = manifest
    end
  end

  describe "Core types are accessible" do
    test "Session struct is accessible" do
      assert %Session{} = %Session{}
    end

    test "Run struct is accessible" do
      assert %Run{} = %Run{}
    end

    test "Event struct is accessible" do
      assert %Event{} = %Event{}
    end

    test "Capability struct is accessible" do
      assert %Capability{} = %Capability{}
    end

    test "Manifest struct is accessible" do
      assert %Manifest{} = %Manifest{}
    end

    test "Error struct is accessible" do
      assert %Error{code: :test, message: "test"} = %Error{code: :test, message: "test"}
    end
  end

  describe "persistence convenience refs" do
    test "builds store/query/maintenance refs from repo context" do
      repo = AgentSessionManager.TestRepo

      assert AgentSessionManager.session_store(repo) ==
               {AgentSessionManager.Adapters.EctoSessionStore, repo}

      assert AgentSessionManager.query_api(repo) ==
               {AgentSessionManager.Adapters.EctoQueryAPI, repo}

      assert AgentSessionManager.maintenance(repo) ==
               {AgentSessionManager.Adapters.EctoMaintenance, repo}
    end
  end
end
