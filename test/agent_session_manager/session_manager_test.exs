defmodule AgentSessionManager.SessionManagerTest do
  @moduledoc """
  Tests for the SessionManager module.

  SessionManager orchestrates session lifecycle, run execution, and event handling.
  These tests use a mock adapter to verify behaviour without external dependencies.

  Uses Supertester for robust async testing and process isolation.
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Capability
  alias AgentSessionManager.SessionManager

  # ============================================================================
  # Mock Adapter for SessionManager Tests
  # ============================================================================

  defmodule MockAdapter do
    @moduledoc """
    Mock provider adapter for testing SessionManager.
    Uses GenServer to be compatible with ProviderAdapter port.
    Includes TestableGenServer for deterministic async testing.
    """

    @behaviour AgentSessionManager.Ports.ProviderAdapter

    use GenServer
    use Supertester.TestableGenServer

    def start_link(opts \\ []) do
      {name, config} = Keyword.pop(opts, :name)
      initial_state = build_initial_state(config)

      if name do
        GenServer.start_link(__MODULE__, initial_state, name: name)
      else
        GenServer.start_link(__MODULE__, initial_state)
      end
    end

    def stop(adapter) do
      GenServer.stop(adapter)
    end

    defp build_initial_state(opts) do
      %{
        capabilities: Keyword.get(opts, :capabilities, default_capabilities()),
        responses: Keyword.get(opts, :responses, %{}),
        fail_with: Keyword.get(opts, :fail_with),
        execute_count: 0,
        cancelled_runs: []
      }
    end

    defp default_capabilities do
      [
        %Capability{name: "chat", type: :tool, enabled: true},
        %Capability{name: "sampling", type: :sampling, enabled: true}
      ]
    end

    # GenServer callbacks

    @impl GenServer
    def init(state) do
      {:ok, state}
    end

    @impl GenServer
    def handle_call(:name, _from, state) do
      {:reply, "mock", state}
    end

    def handle_call(:capabilities, _from, state) do
      result =
        case state.fail_with do
          nil -> {:ok, state.capabilities}
          error -> {:error, error}
        end

      {:reply, result, state}
    end

    def handle_call({:execute, run, _session, opts}, _from, state) do
      state = %{state | execute_count: state.execute_count + 1}

      result =
        case state.fail_with do
          nil -> execute_mock(state, run, opts)
          error -> {:error, error}
        end

      {:reply, result, state}
    end

    def handle_call({:cancel, run_id}, _from, state) do
      case state.fail_with do
        nil ->
          state = %{state | cancelled_runs: [run_id | state.cancelled_runs]}
          {:reply, {:ok, run_id}, state}

        error ->
          {:reply, {:error, error}, state}
      end
    end

    def handle_call({:validate_config, config}, _from, state) do
      result =
        if Map.has_key?(config, :invalid) do
          {:error, Error.new(:validation_error, "Invalid configuration")}
        else
          :ok
        end

      {:reply, result, state}
    end

    def handle_call(:get_execute_count, _from, state) do
      {:reply, state.execute_count, state}
    end

    def handle_call(:get_cancelled_runs, _from, state) do
      {:reply, state.cancelled_runs, state}
    end

    def handle_call({:set_fail_with, error}, _from, state) do
      {:reply, :ok, %{state | fail_with: error}}
    end

    def handle_call({:set_capabilities, capabilities}, _from, state) do
      {:reply, :ok, %{state | capabilities: capabilities}}
    end

    def handle_call({:set_response, key, response}, _from, state) do
      {:reply, :ok, %{state | responses: Map.put(state.responses, key, response)}}
    end

    # ProviderAdapter behaviour implementation (these delegate to GenServer calls)

    @impl AgentSessionManager.Ports.ProviderAdapter
    def name(adapter), do: GenServer.call(adapter, :name)

    @impl AgentSessionManager.Ports.ProviderAdapter
    def capabilities(adapter), do: GenServer.call(adapter, :capabilities)

    @impl AgentSessionManager.Ports.ProviderAdapter
    def execute(adapter, run, session, opts \\ []) do
      GenServer.call(adapter, {:execute, run, session, opts})
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def cancel(adapter, run_id) do
      GenServer.call(adapter, {:cancel, run_id})
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def validate_config(adapter, config) do
      GenServer.call(adapter, {:validate_config, config})
    end

    defp execute_mock(state, run, opts) do
      response = Map.get(state.responses, :execute, %{content: "Mock response"})
      event_callback = Keyword.get(opts, :event_callback)

      events = [
        build_event(:run_started, run),
        build_event(:message_received, run, %{content: response.content}),
        build_event(:run_completed, run)
      ]

      if event_callback do
        Enum.each(events, event_callback)
      end

      {:ok,
       %{
         output: response,
         token_usage: %{input_tokens: 10, output_tokens: 20},
         events: events
       }}
    end

    defp build_event(type, run, data \\ %{}) do
      base_data =
        case type do
          :run_started ->
            %{
              provider_session_id: "mock-provider-session-123",
              model: "mock-model-v1",
              tools: ["chat", "search"]
            }

          _ ->
            %{}
        end

      %{
        type: type,
        session_id: run.session_id,
        run_id: run.id,
        data: Map.merge(base_data, data),
        timestamp: DateTime.utc_now()
      }
    end

    # Test helpers
    def get_execute_count(adapter) do
      GenServer.call(adapter, :get_execute_count)
    end

    def get_cancelled_runs(adapter) do
      GenServer.call(adapter, :get_cancelled_runs)
    end

    def set_fail_with(adapter, error) do
      GenServer.call(adapter, {:set_fail_with, error})
    end

    def set_capabilities(adapter, capabilities) do
      GenServer.call(adapter, {:set_capabilities, capabilities})
    end

    def set_response(adapter, key, response) do
      GenServer.call(adapter, {:set_response, key, response})
    end
  end

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup ctx do
    {:ok, store} = setup_test_store(ctx)
    {:ok, adapter} = MockAdapter.start_link()

    on_exit(fn ->
      safe_stop(adapter)
    end)

    ctx
    |> Map.put(:store, store)
    |> Map.put(:adapter, adapter)
  end

  # ============================================================================
  # Session Lifecycle Tests
  # ============================================================================

  describe "start_session/3" do
    test "creates a new session with pending status", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})

      assert %Session{} = session
      assert session.agent_id == "test-agent"
      assert session.status == :pending
      assert session.id != nil
    end

    test "stores the session in the session store", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})

      {:ok, retrieved} = SessionStore.get_session(store, session.id)
      assert retrieved.id == session.id
    end

    test "emits session_created event", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})

      {:ok, events} = SessionStore.get_events(store, session.id)
      assert Enum.any?(events, &(&1.type == :session_created))
    end

    test "validates agent_id is required", %{store: store, adapter: adapter} do
      assert {:error, %Error{code: :validation_error}} =
               SessionManager.start_session(store, adapter, %{})
    end

    test "accepts optional metadata and context", %{store: store, adapter: adapter} do
      {:ok, session} =
        SessionManager.start_session(store, adapter, %{
          agent_id: "test-agent",
          metadata: %{user_id: "user-123"},
          context: %{system_prompt: "You are helpful"}
        })

      assert session.metadata.user_id == "user-123"
      assert session.context.system_prompt == "You are helpful"
    end
  end

  describe "get_session/2" do
    test "retrieves an existing session", %{store: store, adapter: adapter} do
      {:ok, created} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})

      {:ok, retrieved} = SessionManager.get_session(store, created.id)

      assert retrieved.id == created.id
      assert retrieved.agent_id == created.agent_id
    end

    test "returns error for non-existent session", %{store: store} do
      assert {:error, %Error{code: :session_not_found}} =
               SessionManager.get_session(store, "non-existent")
    end
  end

  describe "activate_session/2" do
    test "updates session status to active", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})

      {:ok, activated} = SessionManager.activate_session(store, session.id)

      assert activated.status == :active
    end

    test "stores the updated session", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      {:ok, retrieved} = SessionStore.get_session(store, session.id)
      assert retrieved.status == :active
    end

    test "emits session_started event", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      {:ok, events} = SessionStore.get_events(store, session.id)
      assert Enum.any?(events, &(&1.type == :session_started))
    end
  end

  # ============================================================================
  # Run Execution Tests
  # ============================================================================

  describe "start_run/4" do
    test "creates a new run with pending status", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      assert %Run{} = run
      assert run.session_id == session.id
      assert run.status == :pending
      assert run.input == %{prompt: "Hello"}
    end

    test "stores the run in the session store", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      {:ok, retrieved} = SessionStore.get_run(store, run.id)
      assert retrieved.id == run.id
    end

    test "returns error for non-existent session", %{store: store, adapter: adapter} do
      assert {:error, %Error{code: :session_not_found}} =
               SessionManager.start_run(store, adapter, "non-existent", %{prompt: "Hello"})
    end
  end

  describe "execute_run/4" do
    test "executes a run via the adapter", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      {:ok, result} = SessionManager.execute_run(store, adapter, run.id)

      assert is_map(result.output)
      assert MockAdapter.get_execute_count(adapter) == 1
    end

    test "updates run status to running then completed", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, completed_run} = SessionStore.get_run(store, run.id)
      assert completed_run.status == :completed
    end

    test "stores events emitted during execution", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)
      types = Enum.map(events, & &1.type)

      assert :run_started in types
      assert :message_received in types
      assert :run_completed in types
    end

    test "updates token usage on run", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, completed_run} = SessionStore.get_run(store, run.id)
      assert completed_run.token_usage.input_tokens == 10
      assert completed_run.token_usage.output_tokens == 20
    end

    test "sets run status to failed on adapter error", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      error = Error.new(:provider_error, "Execution failed")
      MockAdapter.set_fail_with(adapter, error)

      {:error, _} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, failed_run} = SessionStore.get_run(store, run.id)
      assert failed_run.status == :failed
    end

    test "emits run_failed event on error", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      error = Error.new(:provider_error, "Execution failed")
      MockAdapter.set_fail_with(adapter, error)

      {:error, _} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)
      assert Enum.any?(events, &(&1.type == :run_failed))
    end
  end

  describe "cancel_run/3" do
    test "cancels an in-progress run", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      # Update run to running status
      {:ok, running_run} = Run.update_status(run, :running)
      :ok = SessionStore.save_run(store, running_run)

      {:ok, cancelled_id} = SessionManager.cancel_run(store, adapter, run.id)

      assert cancelled_id == run.id
      assert run.id in MockAdapter.get_cancelled_runs(adapter)
    end

    test "updates run status to cancelled", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      {:ok, running_run} = Run.update_status(run, :running)
      :ok = SessionStore.save_run(store, running_run)

      {:ok, _} = SessionManager.cancel_run(store, adapter, run.id)

      {:ok, cancelled_run} = SessionStore.get_run(store, run.id)
      assert cancelled_run.status == :cancelled
    end

    test "emits run_cancelled event", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      {:ok, running_run} = Run.update_status(run, :running)
      :ok = SessionStore.save_run(store, running_run)

      {:ok, _} = SessionManager.cancel_run(store, adapter, run.id)

      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)
      assert Enum.any?(events, &(&1.type == :run_cancelled))
    end
  end

  # ============================================================================
  # Capability Enforcement Tests
  # ============================================================================

  describe "capability enforcement" do
    test "allows run when adapter has required capabilities", %{store: store, adapter: adapter} do
      # Default adapter has :tool and :sampling capabilities
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Require :tool capability
      opts = [required_capabilities: [:tool]]
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"}, opts)
      {:ok, _result} = SessionManager.execute_run(store, adapter, run.id)

      assert MockAdapter.get_execute_count(adapter) == 1
    end

    test "rejects run when adapter missing required capabilities", %{
      store: store,
      adapter: adapter
    } do
      # Set adapter to only have :tool capability
      MockAdapter.set_capabilities(adapter, [
        %Capability{name: "chat", type: :tool, enabled: true}
      ])

      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Require :file_access capability (not available)
      opts = [required_capabilities: [:file_access]]

      assert {:error, %Error{code: :missing_required_capability}} =
               SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"}, opts)
    end

    test "warns but allows run when optional capabilities missing", %{
      store: store,
      adapter: adapter
    } do
      # Set adapter to only have :tool capability
      MockAdapter.set_capabilities(adapter, [
        %Capability{name: "chat", type: :tool, enabled: true}
      ])

      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # Optional :sampling capability (not available)
      opts = [optional_capabilities: [:sampling]]
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"}, opts)

      assert %Run{} = run
    end
  end

  # ============================================================================
  # Session Completion Tests
  # ============================================================================

  describe "complete_session/2" do
    test "updates session status to completed", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      {:ok, completed} = SessionManager.complete_session(store, session.id)

      assert completed.status == :completed
    end

    test "emits session_completed event", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, _} = SessionManager.complete_session(store, session.id)

      {:ok, events} = SessionStore.get_events(store, session.id)
      assert Enum.any?(events, &(&1.type == :session_completed))
    end
  end

  describe "fail_session/3" do
    test "updates session status to failed", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      error = Error.new(:internal_error, "Something went wrong")
      {:ok, failed} = SessionManager.fail_session(store, session.id, error)

      assert failed.status == :failed
    end

    test "emits session_failed event with error details", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      error = Error.new(:internal_error, "Something went wrong")
      {:ok, _} = SessionManager.fail_session(store, session.id, error)

      {:ok, events} = SessionStore.get_events(store, session.id)
      failed_event = Enum.find(events, &(&1.type == :session_failed))
      assert failed_event != nil
      assert failed_event.data.error_code == :internal_error
    end
  end

  # ============================================================================
  # Event Query Tests
  # ============================================================================

  describe "get_session_events/3" do
    test "returns all events for a session", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, events} = SessionManager.get_session_events(store, session.id)

      assert length(events) >= 4
    end

    test "filters events by run_id", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, events} = SessionManager.get_session_events(store, session.id, run_id: run.id)

      assert Enum.all?(events, &(&1.run_id == run.id))
    end
  end

  describe "get_session_runs/2" do
    test "returns all runs for a session", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, _run1} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, _run2} = SessionManager.start_run(store, adapter, session.id, %{prompt: "World"})

      {:ok, runs} = SessionManager.get_session_runs(store, session.id)

      assert length(runs) == 2
    end
  end

  # ============================================================================
  # Provider Metadata Preservation Tests
  # ============================================================================

  describe "provider metadata preservation" do
    test "start_session stores provider name in session metadata", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})

      assert session.metadata.provider == "mock"
    end

    test "start_session preserves user-provided metadata alongside provider metadata", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session} =
        SessionManager.start_session(store, adapter, %{
          agent_id: "test-agent",
          metadata: %{user_id: "user-123", custom_field: "custom_value"}
        })

      assert session.metadata.provider == "mock"
      assert session.metadata.user_id == "user-123"
      assert session.metadata.custom_field == "custom_value"
    end

    test "execute_run updates session with provider_session_id from run_started event", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, _result} = SessionManager.execute_run(store, adapter, run.id)

      # Retrieve updated session
      {:ok, updated_session} = SessionStore.get_session(store, session.id)

      assert updated_session.metadata.provider_session_id == "mock-provider-session-123"
    end

    test "execute_run updates session with model info from run_started event", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, _result} = SessionManager.execute_run(store, adapter, run.id)

      # Retrieve updated session
      {:ok, updated_session} = SessionStore.get_session(store, session.id)

      assert updated_session.metadata.model == "mock-model-v1"
    end

    test "execute_run stores provider metadata in run metadata", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, _result} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, updated_run} = SessionStore.get_run(store, run.id)

      assert updated_run.metadata.provider == "mock"
      assert updated_run.metadata.provider_session_id == "mock-provider-session-123"
    end

    test "subsequent runs preserve existing provider_session_id", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      # First run
      {:ok, run1} = SessionManager.start_run(store, adapter, session.id, %{prompt: "First"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run1.id)

      # Second run
      {:ok, run2} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Second"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run2.id)

      # Session should still have the provider_session_id
      {:ok, updated_session} = SessionStore.get_session(store, session.id)
      assert updated_session.metadata.provider_session_id == "mock-provider-session-123"

      # Both runs should have provider metadata
      {:ok, updated_run1} = SessionStore.get_run(store, run1.id)
      {:ok, updated_run2} = SessionStore.get_run(store, run2.id)

      assert updated_run1.metadata.provider_session_id == "mock-provider-session-123"
      assert updated_run2.metadata.provider_session_id == "mock-provider-session-123"
    end

    test "session_created event includes provider in data", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})

      {:ok, events} = SessionStore.get_events(store, session.id)
      created_event = Enum.find(events, &(&1.type == :session_created))

      assert created_event.data.provider == "mock"
    end
  end
end
