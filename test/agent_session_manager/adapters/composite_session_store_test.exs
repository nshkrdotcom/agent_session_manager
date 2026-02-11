defmodule AgentSessionManager.Adapters.CompositeSessionStoreTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.{
    CompositeSessionStore,
    FileArtifactStore,
    InMemorySessionStore
  }

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Ports.{ArtifactStore, SessionStore}

  import AgentSessionManager.Test.Fixtures

  defmodule CrashingArtifactStore do
    use GenServer

    @behaviour AgentSessionManager.Ports.ArtifactStore

    @impl AgentSessionManager.Ports.ArtifactStore
    def put(store, key, data, opts \\ []),
      do: GenServer.call(store, {:put_artifact, key, data, opts})

    @impl AgentSessionManager.Ports.ArtifactStore
    def get(store, key, opts \\ []), do: GenServer.call(store, {:get_artifact, key, opts})

    @impl AgentSessionManager.Ports.ArtifactStore
    def delete(store, key, opts \\ []),
      do: GenServer.call(store, {:delete_artifact, key, opts})

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl GenServer
    def init(_opts), do: {:ok, %{}}

    @impl GenServer
    def handle_call({:put_artifact, _key, _data, _opts}, _from, _state) do
      raise "simulated artifact store crash"
    end

    def handle_call({:get_artifact, _key, _opts}, _from, _state) do
      raise "simulated artifact store crash"
    end

    def handle_call({:delete_artifact, _key, _opts}, _from, _state) do
      raise "simulated artifact store crash"
    end
  end

  setup _ctx do
    {:ok, session_store} = InMemorySessionStore.start_link()

    artifact_root =
      Path.join(
        System.tmp_dir!(),
        "asm_composite_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    {:ok, artifact_store} = FileArtifactStore.start_link(root: artifact_root)

    {:ok, composite} =
      CompositeSessionStore.start_link(
        session_store: session_store,
        artifact_store: artifact_store
      )

    cleanup_on_exit(fn -> safe_stop(composite) end)
    cleanup_on_exit(fn -> safe_stop(session_store) end)
    cleanup_on_exit(fn -> safe_stop(artifact_store) end)
    cleanup_on_exit(fn -> File.rm_rf(artifact_root) end)

    %{composite: composite, session_store: session_store, artifact_store: artifact_store}
  end

  # ============================================================================
  # SessionStore delegation
  # ============================================================================

  describe "SessionStore operations" do
    test "save and get session", %{composite: store} do
      session = build_session(agent_id: "test-agent")
      :ok = SessionStore.save_session(store, session)

      {:ok, retrieved} = SessionStore.get_session(store, session.id)
      assert retrieved.id == session.id
      assert retrieved.agent_id == "test-agent"
    end

    test "list sessions", %{composite: store} do
      s1 = build_session(index: 1, agent_id: "agent-1")
      s2 = build_session(index: 2, agent_id: "agent-2")
      :ok = SessionStore.save_session(store, s1)
      :ok = SessionStore.save_session(store, s2)

      {:ok, sessions} = SessionStore.list_sessions(store)
      assert length(sessions) == 2
    end

    test "delete session", %{composite: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)
      :ok = SessionStore.delete_session(store, session.id)

      {:error, %Error{code: :session_not_found}} =
        SessionStore.get_session(store, session.id)
    end

    test "save and get run", %{composite: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)

      run = build_run(session_id: session.id)
      :ok = SessionStore.save_run(store, run)

      {:ok, retrieved} = SessionStore.get_run(store, run.id)
      assert retrieved.id == run.id
    end

    test "list runs", %{composite: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)

      r1 = build_run(index: 1, session_id: session.id)
      r2 = build_run(index: 2, session_id: session.id)
      :ok = SessionStore.save_run(store, r1)
      :ok = SessionStore.save_run(store, r2)

      {:ok, runs} = SessionStore.list_runs(store, session.id)
      assert length(runs) == 2
    end

    test "get active run", %{composite: store} do
      session = build_session()
      :ok = SessionStore.save_session(store, session)

      run = build_run(session_id: session.id, status: :running)
      :ok = SessionStore.save_run(store, run)

      {:ok, active} = SessionStore.get_active_run(store, session.id)
      assert active.id == run.id
    end

    test "append and get events", %{composite: store} do
      event = build_event(type: :session_created)
      {:ok, stored} = SessionStore.append_event_with_sequence(store, event)
      assert stored.sequence_number == 1

      {:ok, events} = SessionStore.get_events(store, event.session_id)
      assert length(events) == 1
    end

    test "get latest sequence", %{composite: store} do
      e1 = build_event(index: 1, type: :run_started)
      e2 = build_event(index: 2, type: :run_completed)

      {:ok, _} = SessionStore.append_event_with_sequence(store, e1)
      {:ok, _} = SessionStore.append_event_with_sequence(store, e2)

      {:ok, latest} = SessionStore.get_latest_sequence(store, e1.session_id)
      assert latest == 2
    end

    test "direct get_events/3 call respects wait_timeout_ms timeout window", %{
      composite: composite,
      session_store: session_store
    } do
      session_id = "ses_wait_timeout_direct"
      test_pid = self()

      task =
        Task.async(fn ->
          send(test_pid, :reader_started)

          CompositeSessionStore.get_events(composite, session_id,
            after: 0,
            wait_timeout_ms: 5_200
          )
        end)

      assert_receive :reader_started, 1_000
      Process.sleep(5_050)

      event = build_event(index: 3301, session_id: session_id, type: :session_created)
      {:ok, _} = SessionStore.append_event_with_sequence(session_store, event)

      assert {:ok, [received]} = Task.await(task, 7_000)
      assert received.session_id == session_id
    end
  end

  # ============================================================================
  # ArtifactStore delegation
  # ============================================================================

  describe "ArtifactStore operations" do
    test "put and get artifact", %{composite: store} do
      :ok = ArtifactStore.put(store, "test-key", "test data")
      {:ok, data} = ArtifactStore.get(store, "test-key")
      assert data == "test data"
    end

    test "delete artifact", %{composite: store} do
      :ok = ArtifactStore.put(store, "to-delete", "data")
      :ok = ArtifactStore.delete(store, "to-delete")

      {:error, %Error{code: :not_found}} = ArtifactStore.get(store, "to-delete")
    end

    test "artifact not found", %{composite: store} do
      {:error, %Error{code: :not_found}} = ArtifactStore.get(store, "nonexistent")
    end
  end

  # ============================================================================
  # Combined operations
  # ============================================================================

  describe "combined session + artifact operations" do
    test "stores sessions and artifacts independently", %{composite: store} do
      # Store a session
      session = build_session(agent_id: "agent-1")
      :ok = SessionStore.save_session(store, session)

      # Store an artifact
      :ok = ArtifactStore.put(store, "snapshot-#{session.id}", "workspace state")

      # Both retrievable independently
      {:ok, retrieved_session} = SessionStore.get_session(store, session.id)
      assert retrieved_session.agent_id == "agent-1"

      {:ok, retrieved_artifact} = ArtifactStore.get(store, "snapshot-#{session.id}")
      assert retrieved_artifact == "workspace state"

      # Delete session doesn't affect artifact
      :ok = SessionStore.delete_session(store, session.id)
      {:ok, _} = ArtifactStore.get(store, "snapshot-#{session.id}")
    end

    @tag capture_log: true
    test "artifact store crashes are isolated from session store operations" do
      {:ok, session_store} = InMemorySessionStore.start_link()
      {:ok, artifact_store} = GenServer.start(CrashingArtifactStore, [])

      {:ok, composite} =
        CompositeSessionStore.start_link(
          session_store: session_store,
          artifact_store: artifact_store
        )

      cleanup_on_exit(fn -> safe_stop(composite) end)
      cleanup_on_exit(fn -> safe_stop(session_store) end)
      cleanup_on_exit(fn -> safe_stop(artifact_store) end)

      assert {:error, %Error{code: :storage_error}} =
               ArtifactStore.put(composite, "boom", "data")

      assert Process.alive?(composite)

      session = build_session(index: 8801, agent_id: "still-works")
      assert :ok = SessionStore.save_session(composite, session)
      assert {:ok, retrieved} = SessionStore.get_session(composite, session.id)
      assert retrieved.agent_id == "still-works"
    end
  end
end
