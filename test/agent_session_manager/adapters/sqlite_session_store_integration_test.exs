defmodule AgentSessionManager.Adapters.SQLiteSessionStoreIntegrationTest do
  @moduledoc """
  Integration tests for the SQLiteSessionStore adapter.

  These tests verify that the SQLiteSessionStore works correctly
  when used as the storage backend for the SessionManager,
  exercising the full session lifecycle through the orchestration layer.
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.SQLiteSessionStore
  alias AgentSessionManager.Core.{Error, Event}
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager

  # ============================================================================
  # Mock Adapter
  # ============================================================================

  defmodule MockAdapter do
    @behaviour AgentSessionManager.Ports.ProviderAdapter

    use GenServer
    use Supertester.TestableGenServer

    alias AgentSessionManager.Core.Capability

    def start_link(opts \\ []) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl GenServer
    def init(_opts), do: {:ok, %{}}

    @impl AgentSessionManager.Ports.ProviderAdapter
    def name(_), do: "mock_sqlite_test"

    @impl AgentSessionManager.Ports.ProviderAdapter
    def capabilities(_adapter) do
      {:ok,
       [
         %Capability{name: "chat", type: :tool, enabled: true},
         %Capability{name: "sampling", type: :sampling, enabled: true}
       ]}
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def execute(_adapter, run, _session, opts) do
      event_callback = Keyword.get(opts, :event_callback)

      if event_callback do
        event_callback.(%{type: :run_started, run_id: run.id})
      end

      result = %{
        output: %{content: "Mock response"},
        token_usage: %{input_tokens: 10, output_tokens: 20},
        events: []
      }

      if event_callback do
        event_callback.(%{type: :run_completed, run_id: run.id})
      end

      {:ok, result}
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def cancel(_adapter, _run_id), do: {:ok, :cancelled}

    @impl AgentSessionManager.Ports.ProviderAdapter
    def validate_config(_, _), do: :ok

    @impl GenServer
    def handle_call(:name, _from, state), do: {:reply, "mock_sqlite_test", state}
    def handle_call(:capabilities, _from, state), do: {:reply, {:ok, []}, state}
  end

  # ============================================================================
  # Setup
  # ============================================================================

  setup _ctx do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "asm_sqlite_integ_#{System.unique_integer([:positive, :monotonic])}.db"
      )

    {:ok, store} = SQLiteSessionStore.start_link(path: db_path)
    {:ok, adapter} = MockAdapter.start_link()

    cleanup_on_exit(fn -> safe_stop(store) end)
    cleanup_on_exit(fn -> safe_stop(adapter) end)
    cleanup_on_exit(fn -> File.rm(db_path) end)
    cleanup_on_exit(fn -> File.rm(db_path <> "-wal") end)
    cleanup_on_exit(fn -> File.rm(db_path <> "-shm") end)

    %{store: store, adapter: adapter, db_path: db_path}
  end

  # ============================================================================
  # Full Session Lifecycle
  # ============================================================================

  describe "full session lifecycle with SessionManager" do
    test "create, activate, run, and complete a session", %{store: store, adapter: adapter} do
      # 1. Create session
      {:ok, session} =
        SessionManager.start_session(store, adapter, %{
          agent_id: "test-agent",
          context: %{system_prompt: "You are helpful"}
        })

      assert session.status == :pending
      assert session.agent_id == "test-agent"

      # 2. Verify persisted
      {:ok, retrieved} = SessionStore.get_session(store, session.id)
      assert retrieved.id == session.id
      assert retrieved.agent_id == "test-agent"

      # 3. Activate session
      {:ok, activated} = SessionManager.activate_session(store, session.id)
      assert activated.status == :active

      # 4. Start a run
      {:ok, run} =
        SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      assert run.status == :pending
      assert run.session_id == session.id

      # 5. Verify run is persisted
      {:ok, retrieved_run} = SessionStore.get_run(store, run.id)
      assert retrieved_run.id == run.id

      # 6. Complete session
      {:ok, completed} = SessionManager.complete_session(store, session.id)
      assert completed.status == :completed

      # 7. Verify final state
      {:ok, final} = SessionStore.get_session(store, session.id)
      assert final.status == :completed
    end

    test "events are persisted during session lifecycle", %{store: store, adapter: adapter} do
      {:ok, session} =
        SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})

      {:ok, events} = SessionStore.get_events(store, session.id)
      # SessionManager emits session_created event
      assert [_ | _] = events

      types = Enum.map(events, & &1.type)
      assert :session_created in types
    end

    test "multiple sessions are isolated", %{store: store, adapter: adapter} do
      {:ok, s1} =
        SessionManager.start_session(store, adapter, %{agent_id: "agent-1"})

      {:ok, s2} =
        SessionManager.start_session(store, adapter, %{agent_id: "agent-2"})

      {:ok, sessions} = SessionStore.list_sessions(store)
      assert length(sessions) >= 2

      ids = Enum.map(sessions, & &1.id)
      assert s1.id in ids
      assert s2.id in ids

      # Events are isolated
      {:ok, e1} = SessionStore.get_events(store, s1.id)
      {:ok, e2} = SessionStore.get_events(store, s2.id)

      assert Enum.all?(e1, &(&1.session_id == s1.id))
      assert Enum.all?(e2, &(&1.session_id == s2.id))
    end
  end

  # ============================================================================
  # Persistence Durability
  # ============================================================================

  describe "data survives store restart" do
    test "sessions survive restart", %{db_path: db_path} do
      # Start first instance and write data
      {:ok, store1} = SQLiteSessionStore.start_link(path: db_path)

      {:ok, _event} =
        Event.new(%{type: :session_created, session_id: "restart-test"})

      session_attrs = %{
        id: "ses_restart",
        agent_id: "test-agent",
        status: :active,
        metadata: %{},
        context: %{},
        tags: [],
        created_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      }

      session = struct!(AgentSessionManager.Core.Session, session_attrs)
      :ok = SessionStore.save_session(store1, session)

      # Stop first instance
      GenServer.stop(store1)

      # Start second instance against same file
      {:ok, store2} = SQLiteSessionStore.start_link(path: db_path)

      # Data should still be there
      {:ok, retrieved} = SessionStore.get_session(store2, "ses_restart")
      assert retrieved.agent_id == "test-agent"
      assert retrieved.status == :active

      GenServer.stop(store2)
    end

    test "events survive restart with correct sequence", %{db_path: db_path} do
      {:ok, store1} = SQLiteSessionStore.start_link(path: db_path)

      {:ok, e1} =
        Event.new(%{type: :session_created, session_id: "ses_seq_restart"})

      {:ok, e2} =
        Event.new(%{type: :run_started, session_id: "ses_seq_restart"})

      {:ok, _} = SessionStore.append_event_with_sequence(store1, e1)
      {:ok, _} = SessionStore.append_event_with_sequence(store1, e2)

      GenServer.stop(store1)

      # Restart
      {:ok, store2} = SQLiteSessionStore.start_link(path: db_path)

      # Sequence should continue from where it left off
      {:ok, latest} = SessionStore.get_latest_sequence(store2, "ses_seq_restart")
      assert latest == 2

      {:ok, e3} =
        Event.new(%{type: :run_completed, session_id: "ses_seq_restart"})

      {:ok, stored} = SessionStore.append_event_with_sequence(store2, e3)
      assert stored.sequence_number == 3

      GenServer.stop(store2)
    end
  end

  # ============================================================================
  # Concurrent Access
  # ============================================================================

  describe "concurrent operations" do
    test "concurrent event appends produce unique sequences", %{store: store} do
      session_id = "ses_concurrent"
      count = 20

      tasks =
        for i <- 1..count do
          Task.async(fn ->
            {:ok, event} =
              Event.new(%{
                type: :message_received,
                session_id: session_id,
                data: %{index: i}
              })

            SessionStore.append_event_with_sequence(store, event)
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # All should succeed
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # All sequence numbers should be unique
      sequences =
        results
        |> Enum.map(fn {:ok, event} -> event.sequence_number end)
        |> Enum.sort()

      assert sequences == Enum.to_list(1..count)
    end

    test "concurrent session writes don't corrupt data", %{store: store} do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            session_attrs = %{
              id: "ses_conc_#{i}",
              agent_id: "agent-#{i}",
              status: :pending,
              metadata: %{},
              context: %{},
              tags: [],
              created_at: DateTime.utc_now(),
              updated_at: DateTime.utc_now()
            }

            session = struct!(AgentSessionManager.Core.Session, session_attrs)
            SessionStore.save_session(store, session)
          end)
        end

      results = Task.await_many(tasks, 10_000)
      assert Enum.all?(results, &(&1 == :ok))

      {:ok, sessions} = SessionStore.list_sessions(store)
      assert length(sessions) == 10
    end
  end

  # ============================================================================
  # Error Handling
  # ============================================================================

  describe "error handling" do
    test "getting non-existent session returns proper error", %{store: store} do
      {:error, %Error{code: :session_not_found}} =
        SessionStore.get_session(store, "ses_does_not_exist")
    end

    test "getting non-existent run returns proper error", %{store: store} do
      {:error, %Error{code: :run_not_found}} =
        SessionStore.get_run(store, "run_does_not_exist")
    end

    test "listing sessions from empty store returns empty list", %{store: store} do
      {:ok, []} = SessionStore.list_sessions(store)
    end
  end
end
