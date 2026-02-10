defmodule AgentSessionManager.Adapters.CompositeSessionStore do
  @moduledoc """
  Combines a SessionStore and an ArtifactStore into a single unified interface.

  The CompositeSessionStore delegates session/run/event operations to the
  configured SessionStore backend and artifact operations to the configured
  ArtifactStore backend.

  ## Usage

      {:ok, session_store} = EctoSessionStore.start_link(repo: MyApp.Repo)
      {:ok, s3} = S3ArtifactStore.start_link(bucket: "artifacts")

      {:ok, store} = CompositeSessionStore.start_link(
        session_store: session_store,
        artifact_store: s3
      )

      # Session operations delegate to SessionStore
      :ok = SessionStore.save_session(store, session)

      # Artifact operations delegate to S3
      :ok = ArtifactStore.put(store, "key", data)

  """

  use GenServer

  @behaviour AgentSessionManager.Ports.SessionStore
  @behaviour AgentSessionManager.Ports.ArtifactStore

  alias AgentSessionManager.Ports.{ArtifactStore, SessionStore}

  # ============================================================================
  # SessionStore Behaviour
  # ============================================================================

  @impl SessionStore
  def save_session(store, session), do: GenServer.call(store, {:save_session, session})

  @impl SessionStore
  def get_session(store, session_id), do: GenServer.call(store, {:get_session, session_id})

  @impl SessionStore
  def list_sessions(store, opts \\ []), do: GenServer.call(store, {:list_sessions, opts})

  @impl SessionStore
  def delete_session(store, session_id),
    do: GenServer.call(store, {:delete_session, session_id})

  @impl SessionStore
  def save_run(store, run), do: GenServer.call(store, {:save_run, run})

  @impl SessionStore
  def get_run(store, run_id), do: GenServer.call(store, {:get_run, run_id})

  @impl SessionStore
  def list_runs(store, session_id, opts \\ []),
    do: GenServer.call(store, {:list_runs, session_id, opts})

  @impl SessionStore
  def get_active_run(store, session_id),
    do: GenServer.call(store, {:get_active_run, session_id})

  @impl SessionStore
  def append_event(store, event), do: GenServer.call(store, {:append_event, event})

  @impl SessionStore
  def append_event_with_sequence(store, event),
    do: GenServer.call(store, {:append_event_with_sequence, event})

  @impl SessionStore
  def append_events(store, events), do: GenServer.call(store, {:append_events, events})

  @impl SessionStore
  def flush(store, execution_result), do: GenServer.call(store, {:flush, execution_result})

  @impl SessionStore
  def get_events(store, session_id, opts \\ []),
    do: GenServer.call(store, {:get_events, session_id, opts})

  @impl SessionStore
  def get_latest_sequence(store, session_id),
    do: GenServer.call(store, {:get_latest_sequence, session_id})

  # ============================================================================
  # ArtifactStore Behaviour
  # ============================================================================

  @impl ArtifactStore
  def put(store, key, data, opts \\ []),
    do: GenServer.call(store, {:put_artifact, key, data, opts})

  @impl ArtifactStore
  def get(store, key, opts \\ []),
    do: GenServer.call(store, {:get_artifact, key, opts})

  @impl ArtifactStore
  def delete(store, key, opts \\ []),
    do: GenServer.call(store, {:delete_artifact, key, opts})

  # ============================================================================
  # GenServer
  # ============================================================================

  def start_link(opts) do
    session_store = Keyword.fetch!(opts, :session_store)
    artifact_store = Keyword.fetch!(opts, :artifact_store)
    name = Keyword.get(opts, :name)

    state = %{session_store: session_store, artifact_store: artifact_store}
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, state, gen_opts)
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  # -- Session delegations --

  @impl GenServer
  def handle_call({:save_session, session}, _from, state) do
    {:reply, SessionStore.save_session(state.session_store, session), state}
  end

  def handle_call({:get_session, session_id}, _from, state) do
    {:reply, SessionStore.get_session(state.session_store, session_id), state}
  end

  def handle_call({:list_sessions, opts}, _from, state) do
    {:reply, SessionStore.list_sessions(state.session_store, opts), state}
  end

  def handle_call({:delete_session, session_id}, _from, state) do
    {:reply, SessionStore.delete_session(state.session_store, session_id), state}
  end

  def handle_call({:save_run, run}, _from, state) do
    {:reply, SessionStore.save_run(state.session_store, run), state}
  end

  def handle_call({:get_run, run_id}, _from, state) do
    {:reply, SessionStore.get_run(state.session_store, run_id), state}
  end

  def handle_call({:list_runs, session_id, opts}, _from, state) do
    {:reply, SessionStore.list_runs(state.session_store, session_id, opts), state}
  end

  def handle_call({:get_active_run, session_id}, _from, state) do
    {:reply, SessionStore.get_active_run(state.session_store, session_id), state}
  end

  def handle_call({:append_event, event}, _from, state) do
    {:reply, SessionStore.append_event(state.session_store, event), state}
  end

  def handle_call({:append_event_with_sequence, event}, _from, state) do
    {:reply, SessionStore.append_event_with_sequence(state.session_store, event), state}
  end

  def handle_call({:append_events, events}, _from, state) do
    {:reply, SessionStore.append_events(state.session_store, events), state}
  end

  def handle_call({:flush, execution_result}, _from, state) do
    {:reply, SessionStore.flush(state.session_store, execution_result), state}
  end

  def handle_call({:get_events, session_id, opts}, _from, state) do
    {:reply, SessionStore.get_events(state.session_store, session_id, opts), state}
  end

  def handle_call({:get_latest_sequence, session_id}, _from, state) do
    {:reply, SessionStore.get_latest_sequence(state.session_store, session_id), state}
  end

  # -- Artifact delegations --

  def handle_call({:put_artifact, key, data, opts}, _from, state) do
    {:reply, ArtifactStore.put(state.artifact_store, key, data, opts), state}
  end

  def handle_call({:get_artifact, key, opts}, _from, state) do
    {:reply, ArtifactStore.get(state.artifact_store, key, opts), state}
  end

  def handle_call({:delete_artifact, key, opts}, _from, state) do
    {:reply, ArtifactStore.delete(state.artifact_store, key, opts), state}
  end
end
