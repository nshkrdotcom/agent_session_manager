defmodule AgentSessionManager.Adapters.CompositeSessionStoreIntegrationTest do
  @moduledoc """
  Integration tests for the CompositeSessionStore adapter.

  Exercises the composite store with Ecto/SQLite for sessions and
  file-based storage for artifacts, verifying both subsystems
  work together through the SessionManager.
  """

  use AgentSessionManager.SupertesterCase, async: false

  alias AgentSessionManager.Adapters.{
    CompositeSessionStore,
    EctoSessionStore,
    EctoSessionStore.Migration,
    FileArtifactStore
  }

  alias AgentSessionManager.Ports.{ArtifactStore, SessionStore}
  alias AgentSessionManager.SessionManager

  alias AgentSessionManager.Adapters.EctoSessionStore.Schemas.{
    ArtifactSchema,
    EventSchema,
    RunSchema,
    SessionSchema,
    SessionSequenceSchema
  }

  defmodule CompositeTestRepo do
    use Ecto.Repo, otp_app: :agent_session_manager, adapter: Ecto.Adapters.SQLite3
  end

  @db_path Path.join(System.tmp_dir!(), "asm_composite_integ.db")

  # Mock adapter for SessionManager integration
  defmodule MockAdapter do
    @behaviour AgentSessionManager.Ports.ProviderAdapter
    use GenServer
    use Supertester.TestableGenServer

    alias AgentSessionManager.Core.Capability

    def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)
    @impl GenServer
    def init(_opts), do: {:ok, %{}}
    @impl AgentSessionManager.Ports.ProviderAdapter
    def name(_), do: "mock_composite"
    @impl AgentSessionManager.Ports.ProviderAdapter
    def capabilities(_), do: {:ok, [%Capability{name: "chat", type: :tool, enabled: true}]}
    @impl AgentSessionManager.Ports.ProviderAdapter
    def execute(_, run, _, opts) do
      cb = Keyword.get(opts, :event_callback)
      if cb, do: cb.(%{type: :run_started, run_id: run.id})
      if cb, do: cb.(%{type: :run_completed, run_id: run.id})

      {:ok,
       %{output: %{content: "ok"}, token_usage: %{input_tokens: 1, output_tokens: 1}, events: []}}
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def cancel(_, _), do: {:ok, :cancelled}
    @impl AgentSessionManager.Ports.ProviderAdapter
    def validate_config(_, _), do: :ok
    @impl GenServer
    def handle_call(:name, _from, s), do: {:reply, "mock_composite", s}
    def handle_call(:capabilities, _from, s), do: {:reply, {:ok, []}, s}
  end

  setup_all do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")

    Application.put_env(:agent_session_manager, CompositeTestRepo,
      database: @db_path,
      pool_size: 1
    )

    {:ok, repo_pid} = CompositeTestRepo.start_link()
    Ecto.Migrator.up(CompositeTestRepo, 1, Migration, log: false)

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
    CompositeTestRepo.delete_all(EventSchema)
    CompositeTestRepo.delete_all(RunSchema)
    CompositeTestRepo.delete_all(ArtifactSchema)
    CompositeTestRepo.delete_all(SessionSequenceSchema)
    CompositeTestRepo.delete_all(SessionSchema)

    artifact_root =
      Path.join(
        System.tmp_dir!(),
        "asm_composite_integ_art_#{System.unique_integer([:positive, :monotonic])}"
      )

    {:ok, session_store} = EctoSessionStore.start_link(repo: CompositeTestRepo)
    {:ok, artifact_store} = FileArtifactStore.start_link(root: artifact_root)

    {:ok, composite} =
      CompositeSessionStore.start_link(
        session_store: session_store,
        artifact_store: artifact_store
      )

    {:ok, adapter} = MockAdapter.start_link()

    cleanup_on_exit(fn -> safe_stop(composite) end)
    cleanup_on_exit(fn -> safe_stop(session_store) end)
    cleanup_on_exit(fn -> safe_stop(artifact_store) end)
    cleanup_on_exit(fn -> safe_stop(adapter) end)
    cleanup_on_exit(fn -> File.rm_rf(artifact_root) end)

    %{composite: composite, adapter: adapter}
  end

  describe "session lifecycle through composite" do
    test "full session flow with SessionManager", %{composite: store, adapter: adapter} do
      {:ok, session} =
        SessionManager.start_session(store, adapter, %{agent_id: "agent-1"})

      assert session.status == :pending

      {:ok, activated} = SessionManager.activate_session(store, session.id)
      assert activated.status == :active

      {:ok, completed} = SessionManager.complete_session(store, session.id)
      assert completed.status == :completed
    end

    test "events persist through composite", %{composite: store, adapter: adapter} do
      {:ok, session} =
        SessionManager.start_session(store, adapter, %{agent_id: "agent-1"})

      {:ok, events} = SessionStore.get_events(store, session.id)
      assert [_ | _] = events
      types = Enum.map(events, & &1.type)
      assert :session_created in types
    end
  end

  describe "artifacts alongside sessions" do
    test "stores workspace snapshot as artifact", %{composite: store, adapter: adapter} do
      {:ok, session} =
        SessionManager.start_session(store, adapter, %{agent_id: "agent-1"})

      snapshot_key = "snapshot-#{session.id}"
      snapshot_data = Jason.encode!(%{files: %{"main.ex" => "defmodule Main do\nend"}})

      :ok = ArtifactStore.put(store, snapshot_key, snapshot_data)
      {:ok, retrieved} = ArtifactStore.get(store, snapshot_key)
      assert retrieved == snapshot_data
    end
  end
end
