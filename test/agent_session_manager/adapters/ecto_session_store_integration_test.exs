defmodule AgentSessionManager.Adapters.EctoSessionStoreIntegrationTest do
  @moduledoc """
  Integration tests for the EctoSessionStore adapter.

  Exercises the adapter through the SessionManager orchestration layer,
  using a SQLite-backed Ecto Repo as the test backend.

  Uses its own Repo module (IntegrationRepo) to avoid name collisions
  with the unit test's TestRepo.
  """

  use AgentSessionManager.SupertesterCase, async: false

  alias AgentSessionManager.Adapters.EctoSessionStore
  alias AgentSessionManager.Adapters.EctoSessionStore.{Migration, MigrationV2, MigrationV3}

  alias AgentSessionManager.Adapters.EctoSessionStore.Schemas.{
    EventSchema,
    RunSchema,
    SessionSchema,
    SessionSequenceSchema
  }

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager

  # Dedicated Ecto Repo for this integration test module (avoids TestRepo conflicts)
  defmodule IntegrationRepo do
    use Ecto.Repo,
      otp_app: :agent_session_manager,
      adapter: Ecto.Adapters.SQLite3
  end

  # ============================================================================
  # Mock Adapter
  # ============================================================================

  defmodule MockAdapter do
    @behaviour AgentSessionManager.Ports.ProviderAdapter

    use GenServer
    use Supertester.TestableGenServer

    alias AgentSessionManager.Core.Capability

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

    @impl GenServer
    def init(_opts), do: {:ok, %{}}

    @impl AgentSessionManager.Ports.ProviderAdapter
    def name(_), do: "mock_ecto_test"

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
      if event_callback, do: event_callback.(%{type: :run_started, run_id: run.id})

      result = %{
        output: %{content: "Mock response"},
        token_usage: %{input_tokens: 10, output_tokens: 20},
        events: []
      }

      if event_callback, do: event_callback.(%{type: :run_completed, run_id: run.id})
      {:ok, result}
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def cancel(_adapter, _run_id), do: {:ok, :cancelled}

    @impl AgentSessionManager.Ports.ProviderAdapter
    def validate_config(_, _), do: :ok

    @impl GenServer
    def handle_call(:name, _from, state), do: {:reply, "mock_ecto_test", state}
    def handle_call(:capabilities, _from, state), do: {:reply, {:ok, []}, state}
  end

  # ============================================================================
  # Setup
  # ============================================================================

  @db_path Path.join(System.tmp_dir!(), "asm_ecto_integ_test.db")

  setup_all _ctx do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")

    Application.put_env(:agent_session_manager, IntegrationRepo,
      database: @db_path,
      pool_size: 1
    )

    {:ok, repo_pid} = IntegrationRepo.start_link()
    Ecto.Migrator.up(IntegrationRepo, 1, Migration, log: false)
    Ecto.Migrator.up(IntegrationRepo, 2, MigrationV2, log: false)

    on_exit(fn ->
      try do
        if Process.alive?(repo_pid), do: Supervisor.stop(repo_pid, :normal)
      catch
        :exit, _ -> :ok
      end

      File.rm(@db_path)
      File.rm(@db_path <> "-wal")
      File.rm(@db_path <> "-shm")
    end)

    :ok
  end

  setup _ctx do
    IntegrationRepo.delete_all(EventSchema)
    IntegrationRepo.delete_all(SessionSequenceSchema)
    IntegrationRepo.delete_all(RunSchema)
    IntegrationRepo.delete_all(SessionSchema)

    {:ok, store} = EctoSessionStore.start_link(repo: IntegrationRepo)
    {:ok, adapter} = MockAdapter.start_link()

    cleanup_on_exit(fn -> safe_stop(store) end)
    cleanup_on_exit(fn -> safe_stop(adapter) end)

    %{store: store, adapter: adapter}
  end

  # ============================================================================
  # Full Session Lifecycle
  # ============================================================================

  describe "full session lifecycle with SessionManager" do
    test "create, activate, run, and complete a session", %{store: store, adapter: adapter} do
      {:ok, session} =
        SessionManager.start_session(store, adapter, %{
          agent_id: "test-agent",
          context: %{system_prompt: "Be helpful"}
        })

      assert session.status == :pending

      {:ok, retrieved} = SessionStore.get_session(store, session.id)
      assert retrieved.id == session.id

      {:ok, activated} = SessionManager.activate_session(store, session.id)
      assert activated.status == :active

      {:ok, run} =
        SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      assert run.session_id == session.id

      {:ok, completed} = SessionManager.complete_session(store, session.id)
      assert completed.status == :completed
    end

    test "events are persisted during session lifecycle", %{store: store, adapter: adapter} do
      {:ok, session} =
        SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})

      {:ok, events} = SessionStore.get_events(store, session.id)
      assert [_ | _] = events

      types = Enum.map(events, & &1.type)
      assert :session_created in types
    end

    test "SessionManager works with module-backed SessionStore ref", %{adapter: adapter} do
      store_ref = {EctoSessionStore, IntegrationRepo}

      {:ok, session} =
        SessionManager.start_session(store_ref, adapter, %{agent_id: "module-backed-agent"})

      assert session.status == :pending

      {:ok, _} = SessionManager.activate_session(store_ref, session.id)
      {:ok, _run} = SessionManager.start_run(store_ref, adapter, session.id, %{prompt: "Hello"})

      {:ok, runs} = SessionStore.list_runs(store_ref, session.id)
      assert length(runs) == 1
    end

    test "multiple sessions are isolated", %{store: store, adapter: adapter} do
      {:ok, s1} =
        SessionManager.start_session(store, adapter, %{agent_id: "agent-1"})

      {:ok, s2} =
        SessionManager.start_session(store, adapter, %{agent_id: "agent-2"})

      {:ok, e1} = SessionStore.get_events(store, s1.id)
      {:ok, e2} = SessionStore.get_events(store, s2.id)

      assert Enum.all?(e1, &(&1.session_id == s1.id))
      assert Enum.all?(e2, &(&1.session_id == s2.id))
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
  end

  describe "migrations" do
    test "MigrationV3.up/0 runs successfully on SQLite" do
      _ = Ecto.Migrator.up(IntegrationRepo, 3, MigrationV3, log: false)
      assert true
    end
  end
end
