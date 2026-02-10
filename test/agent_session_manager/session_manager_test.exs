defmodule AgentSessionManager.SessionManagerTest do
  @moduledoc """
  Tests for the SessionManager module.

  SessionManager orchestrates session lifecycle, run execution, and event handling.
  These tests use a mock adapter to verify behaviour without external dependencies.

  Uses Supertester for robust async testing and process isolation.
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.{Capability, Transcript}
  alias AgentSessionManager.SessionManager
  alias AgentSessionManager.Test.{FlushTrackingStore, RunScopedEventBlindStore}

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
        cancelled_runs: [],
        last_execute_session: nil,
        last_execute_opts: []
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

    def handle_call({:execute, run, session, opts}, _from, state) do
      state = %{
        state
        | execute_count: state.execute_count + 1,
          last_execute_session: session,
          last_execute_opts: opts
      }

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

    def handle_call(:get_last_execute_session, _from, state) do
      {:reply, state.last_execute_session, state}
    end

    def handle_call(:get_last_execute_opts, _from, state) do
      {:reply, state.last_execute_opts, state}
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

      events = build_execute_events(response, run)

      if event_callback do
        Enum.each(events, event_callback)
      end

      output =
        response
        |> Map.drop([:events, :token_usage])
        |> case do
          %{} = map when map_size(map) > 0 -> map
          _ -> %{content: "Mock response"}
        end

      token_usage = Map.get(response, :token_usage, %{input_tokens: 10, output_tokens: 20})

      {:ok,
       %{
         output: output,
         token_usage: token_usage,
         events: events
       }}
    end

    defp build_execute_events(response, run) do
      case Map.get(response, :events) do
        events when is_list(events) and events != [] ->
          Enum.map(events, &normalize_mock_event(&1, run))

        _ ->
          [
            build_event(:run_started, run),
            build_event(:message_received, run, %{content: response.content}),
            build_event(:run_completed, run)
          ]
      end
    end

    defp normalize_mock_event(%{type: _type} = event, run) do
      base = %{
        type: event.type,
        session_id: Map.get(event, :session_id, run.session_id),
        run_id: Map.get(event, :run_id, run.id),
        data: Map.get(event, :data, %{}),
        timestamp: Map.get(event, :timestamp, DateTime.utc_now())
      }

      case Map.get(event, :metadata) do
        nil -> base
        metadata -> Map.put(base, :metadata, metadata)
      end
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

    def get_last_execute_session(adapter) do
      GenServer.call(adapter, :get_last_execute_session)
    end

    def get_last_execute_opts(adapter) do
      GenServer.call(adapter, :get_last_execute_opts)
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

  defmodule StoreKillingAdapter do
    @moduledoc false

    @behaviour AgentSessionManager.Ports.ProviderAdapter

    use GenServer
    use Supertester.TestableGenServer

    alias AgentSessionManager.Core.{Capability, Error}

    def start_link(opts) do
      store = Keyword.fetch!(opts, :store)
      GenServer.start_link(__MODULE__, %{store: store})
    end

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl AgentSessionManager.Ports.ProviderAdapter
    def name(adapter), do: GenServer.call(adapter, :name)

    @impl AgentSessionManager.Ports.ProviderAdapter
    def capabilities(adapter), do: GenServer.call(adapter, :capabilities)

    @impl AgentSessionManager.Ports.ProviderAdapter
    def execute(adapter, run, session, opts \\ []) do
      GenServer.call(adapter, {:execute, run, session, opts})
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def cancel(adapter, run_id), do: GenServer.call(adapter, {:cancel, run_id})

    @impl AgentSessionManager.Ports.ProviderAdapter
    def validate_config(adapter, config), do: GenServer.call(adapter, {:validate_config, config})

    @impl GenServer
    def handle_call(:name, _from, state) do
      {:reply, "store-killer", state}
    end

    def handle_call(:capabilities, _from, state) do
      {:reply, {:ok, [%Capability{name: "chat", type: :tool, enabled: true}]}, state}
    end

    @impl GenServer
    def handle_call({:execute, _run, _session, _opts}, _from, state) do
      _ = safe_stop_store(state.store)

      {:reply,
       {:error,
        Error.new(
          :provider_unavailable,
          "Provider failed after store shutdown"
        )}, state}
    end

    def handle_call({:cancel, run_id}, _from, state) do
      {:reply, {:ok, run_id}, state}
    end

    def handle_call({:validate_config, _config}, _from, state) do
      {:reply, :ok, state}
    end

    defp safe_stop_store(store) when is_pid(store) do
      if Process.alive?(store), do: GenServer.stop(store, :normal)
      :ok
    catch
      :exit, _ -> :ok
    end
  end

  # ============================================================================
  # Test Setup
  # ============================================================================

  setup ctx do
    {:ok, store} = setup_test_store(ctx)
    {:ok, adapter} = MockAdapter.start_link()

    cleanup_on_exit(fn -> safe_stop(adapter) end)

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

    test "persists message_sent events from run input messages before adapter events", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      {:ok, run} =
        SessionManager.start_run(store, adapter, session.id, %{
          messages: [%{role: "user", content: "Hello from user input"}]
        })

      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)

      message_sent = Enum.find(events, &(&1.type == :message_sent))
      run_started_index = Enum.find_index(events, &(&1.type == :run_started))
      message_sent_index = Enum.find_index(events, &(&1.type == :message_sent))

      assert message_sent != nil
      assert message_sent.data.content == "Hello from user input"
      assert message_sent.data.role in ["user", :user]
      assert is_integer(message_sent_index)
      assert is_integer(run_started_index)
      assert message_sent_index < run_started_index
    end

    test "persists message_sent events from prompt input for continuity fallback", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      {:ok, run} =
        SessionManager.start_run(store, adapter, session.id, %{prompt: "Prompt style input"})

      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)
      message_sent_events = Enum.filter(events, &(&1.type == :message_sent))

      assert length(message_sent_events) == 1
      assert hd(message_sent_events).data.content == "Prompt style input"
      assert hd(message_sent_events).data.role in ["user", :user]
    end

    test "normalizes alias event types from adapters", %{store: store, adapter: adapter} do
      MockAdapter.set_response(adapter, :execute, %{
        content: "Normalized response",
        token_usage: %{input_tokens: 7, output_tokens: 11},
        events: [
          %{type: "run_start", data: %{provider_session_id: "prov-123", model: "mock-v2"}},
          %{type: "delta", data: %{content: "part-1"}},
          %{type: "run_end", data: %{status: "success"}}
        ]
      })

      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)
      types = Enum.map(events, & &1.type)

      assert :run_started in types
      assert :message_streamed in types
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

    test "returns storage_connection_failed when store goes down during failed-run finalization" do
      {:ok, store} = setup_test_store(%{})
      {:ok, adapter} = StoreKillingAdapter.start_link(store: store)
      cleanup_on_exit(fn -> safe_stop(adapter) end)
      cleanup_on_exit(fn -> safe_stop(store) end)

      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      assert {:error, %Error{code: :storage_connection_failed}} =
               SessionManager.execute_run(store, adapter, run.id)
    end

    test "injects transcript into session context when continuation is enabled", %{
      store: store,
      adapter: adapter
    } do
      MockAdapter.set_response(adapter, :execute, %{content: "first reply"})

      {:ok, session} =
        SessionManager.start_session(store, adapter, %{
          agent_id: "test-agent",
          context: %{system_prompt: "be concise"}
        })

      {:ok, _} = SessionManager.activate_session(store, session.id)

      {:ok, run_1} = SessionManager.start_run(store, adapter, session.id, %{prompt: "first"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run_1.id)

      {:ok, run_2} = SessionManager.start_run(store, adapter, session.id, %{prompt: "second"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run_2.id, continuation: true)

      execute_session = MockAdapter.get_last_execute_session(adapter)

      assert execute_session.context.system_prompt == "be concise"
      assert %Transcript{} = execute_session.context.transcript

      assert Enum.any?(execute_session.context.transcript.messages, fn message ->
               message.role == :assistant and message.content == "first reply"
             end)

      assert Enum.any?(execute_session.context.transcript.messages, fn message ->
               message.role == :user and message.content == "first"
             end)
    end

    test "does not inject transcript when continuation is disabled", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session} =
        SessionManager.start_session(store, adapter, %{
          agent_id: "test-agent",
          context: %{system_prompt: "be concise"}
        })

      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "hello"})

      {:ok, _} = SessionManager.execute_run(store, adapter, run.id, continuation: false)

      execute_session = MockAdapter.get_last_execute_session(adapter)
      assert execute_session.context.system_prompt == "be concise"
      refute Map.has_key?(execute_session.context, :transcript)
    end

    test "forwards adapter_opts to ProviderAdapter.execute/4 and keeps user callback", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      test_pid = self()

      callback = fn event_data ->
        send(test_pid, {:user_event, event_data.type})
      end

      {:ok, _} =
        SessionManager.execute_run(store, adapter, run.id,
          event_callback: callback,
          adapter_opts: [timeout: 12_345, custom_flag: :enabled]
        )

      execute_opts = MockAdapter.get_last_execute_opts(adapter)

      assert execute_opts[:timeout] == 12_345
      assert execute_opts[:custom_flag] == :enabled
      assert is_function(execute_opts[:event_callback], 1)

      assert_received {:user_event, :run_started}
      assert_received {:user_event, :message_received}
      assert_received {:user_event, :run_completed}
    end

    test "extracts provider metadata without querying run-scoped store events", %{
      adapter: adapter
    } do
      {:ok, store} = RunScopedEventBlindStore.start_link()
      cleanup_on_exit(fn -> safe_stop(store) end)

      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      {:ok, _result} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, stored_run} = SessionStore.get_run(store, run.id)
      assert stored_run.provider_metadata[:provider] == "mock"
      assert stored_run.provider_metadata[:model] == "mock-model-v1"
    end

    test "uses flush to persist final run state", %{adapter: adapter} do
      {:ok, store} = FlushTrackingStore.start_link()
      cleanup_on_exit(fn -> safe_stop(store) end)

      {:ok, result} =
        SessionManager.run_once(store, adapter, %{
          messages: [%{role: "user", content: "hello"}]
        })

      [execution_result] = FlushTrackingStore.flush_calls(store)
      assert execution_result.run.id == result.run_id
      assert execution_result.session.id == result.session_id
      assert is_list(execution_result.events)
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

    test "best-effort cancels when adapter has already stopped", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      {:ok, running_run} = Run.update_status(run, :running)
      :ok = SessionStore.save_run(store, running_run)

      :ok = MockAdapter.stop(adapter)
      run_id = run.id

      assert {:ok, ^run_id} = SessionManager.cancel_run(store, adapter, run_id)

      {:ok, cancelled_run} = SessionStore.get_run(store, run_id)
      assert cancelled_run.status == :cancelled

      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run_id)
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

    test "persists sequence numbers for lifecycle and adapter events", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)
      {:ok, _} = SessionManager.complete_session(store, session.id)

      {:ok, events} = SessionManager.get_session_events(store, session.id)
      sequences = Enum.map(events, & &1.sequence_number)

      assert Enum.all?(sequences, &is_integer/1)
      assert sequences == Enum.sort(sequences)
      assert length(Enum.uniq(sequences)) == length(sequences)
    end

    test "sequence numbers continue monotonically across multiple runs", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      {:ok, run1} = SessionManager.start_run(store, adapter, session.id, %{prompt: "One"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run1.id)

      {:ok, run2} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Two"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run2.id)

      {:ok, events} = SessionManager.get_session_events(store, session.id)
      sequences = Enum.map(events, & &1.sequence_number)

      assert sequences == Enum.sort(sequences)
      assert List.last(sequences) == length(sequences)
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

  describe "stream_session_events/3" do
    test "supports cursor-based pagination", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run1} = SessionManager.start_run(store, adapter, session.id, %{prompt: "One"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run1.id)
      {:ok, run2} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Two"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run2.id)

      first_page =
        SessionManager.stream_session_events(store, session.id, limit: 2, poll_interval_ms: 5)
        |> Enum.take(2)

      last_sequence = List.last(first_page).sequence_number

      second_page =
        SessionManager.stream_session_events(store, session.id,
          after: last_sequence,
          limit: 2,
          poll_interval_ms: 5
        )
        |> Enum.take(2)

      assert length(first_page) == 2
      assert length(second_page) == 2
      assert Enum.all?(second_page, &(&1.sequence_number > last_sequence))
    end

    test "follows new events appended after stream starts", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      {:ok, cursor} = SessionStore.get_latest_sequence(store, session.id)
      test_pid = self()

      Task.start(fn ->
        events =
          SessionManager.stream_session_events(store, session.id,
            after: cursor,
            limit: 3,
            poll_interval_ms: 10
          )
          |> Enum.take(3)

        send(test_pid, {:streamed, events})
      end)

      {:ok, run} =
        SessionManager.start_run(store, adapter, session.id, %{prompt: "Follow stream"})

      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)

      assert_receive {:streamed, streamed_events}, 2_000
      assert length(streamed_events) == 3
      assert Enum.all?(streamed_events, &(&1.sequence_number > cursor))

      assert Enum.map(streamed_events, & &1.type) == [
               :message_sent,
               :run_started,
               :message_received
             ]
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

  # ============================================================================
  # run_once/4 Tests
  # ============================================================================

  describe "run_once/4" do
    test "returns {:ok, result} with output and token_usage", %{store: store, adapter: adapter} do
      {:ok, result} =
        SessionManager.run_once(store, adapter, %{
          messages: [%{role: "user", content: "Hello"}]
        })

      assert is_map(result.output)
      assert result.token_usage.input_tokens == 10
      assert result.token_usage.output_tokens == 20
    end

    test "includes session_id and run_id in result", %{store: store, adapter: adapter} do
      {:ok, result} =
        SessionManager.run_once(store, adapter, %{
          messages: [%{role: "user", content: "Hello"}]
        })

      assert is_binary(result.session_id)
      assert is_binary(result.run_id)
    end

    test "uses adapter provider name as default agent_id", %{store: store, adapter: adapter} do
      {:ok, result} =
        SessionManager.run_once(store, adapter, %{
          messages: [%{role: "user", content: "Hello"}]
        })

      {:ok, session} = SessionStore.get_session(store, result.session_id)
      assert session.agent_id == "mock"
    end

    test "uses custom agent_id when provided", %{store: store, adapter: adapter} do
      {:ok, result} =
        SessionManager.run_once(
          store,
          adapter,
          %{
            messages: [%{role: "user", content: "Hello"}]
          },
          agent_id: "custom-agent"
        )

      {:ok, session} = SessionStore.get_session(store, result.session_id)
      assert session.agent_id == "custom-agent"
    end

    test "session is completed after successful run", %{store: store, adapter: adapter} do
      {:ok, result} =
        SessionManager.run_once(store, adapter, %{
          messages: [%{role: "user", content: "Hello"}]
        })

      {:ok, session} = SessionStore.get_session(store, result.session_id)
      assert session.status == :completed
    end

    test "run is completed after successful execution", %{store: store, adapter: adapter} do
      {:ok, result} =
        SessionManager.run_once(store, adapter, %{
          messages: [%{role: "user", content: "Hello"}]
        })

      {:ok, run} = SessionStore.get_run(store, result.run_id)
      assert run.status == :completed
    end

    test "forwards metadata, context, and tags to session", %{store: store, adapter: adapter} do
      {:ok, result} =
        SessionManager.run_once(store, adapter, %{prompt: "Hello"},
          metadata: %{user_id: "u-1"},
          context: %{system_prompt: "Be helpful"},
          tags: ["test"]
        )

      {:ok, session} = SessionStore.get_session(store, result.session_id)
      assert session.metadata.user_id == "u-1"
      assert session.context.system_prompt == "Be helpful"
      assert session.tags == ["test"]
    end

    test "returns {:error, error} on adapter failure", %{store: store, adapter: adapter} do
      error = Error.new(:provider_error, "Boom")
      MockAdapter.set_fail_with(adapter, error)

      assert {:error, %Error{code: :provider_error}} =
               SessionManager.run_once(store, adapter, %{prompt: "Hello"})
    end

    test "marks session as failed on adapter error", %{store: store} do
      # Use a fresh adapter with fail_with set. MockAdapter.name/1 doesn't check
      # fail_with, and run_once without capability opts skips capabilities check,
      # so only execute_run will fail.
      {:ok, fail_adapter} = MockAdapter.start_link()
      cleanup_on_exit(fn -> safe_stop(fail_adapter) end)

      error = Error.new(:provider_error, "Boom")
      MockAdapter.set_fail_with(fail_adapter, error)

      {:error, _} = SessionManager.run_once(store, fail_adapter, %{prompt: "Hello"})

      {:ok, sessions} = SessionStore.list_sessions(store)
      failed = Enum.find(sessions, &(&1.status == :failed))
      assert failed != nil
      assert failed.status == :failed
    end

    test "returns provider_timeout and marks run/session failed when adapter call times out", %{
      store: store
    } do
      {:ok, timeout_adapter} = MockProviderAdapter.start_link(execution_mode: :timeout)
      cleanup_on_exit(fn -> safe_stop(timeout_adapter) end)

      assert {:error, %Error{code: :provider_timeout}} =
               SessionManager.run_once(store, timeout_adapter, %{prompt: "Hello"},
                 adapter_opts: [timeout: 1]
               )

      {:ok, sessions} = SessionStore.list_sessions(store)
      assert [%Session{status: :failed} = failed_session] = sessions

      {:ok, runs} = SessionStore.list_runs(store, failed_session.id)
      assert [%Run{status: :failed}] = runs
    end

    test "delivers events to user callback in real-time", %{store: store, adapter: adapter} do
      test_pid = self()

      callback = fn event_data ->
        send(test_pid, {:event, event_data.type})
      end

      {:ok, _result} =
        SessionManager.run_once(store, adapter, %{prompt: "Hello"}, event_callback: callback)

      assert_received {:event, :run_started}
      assert_received {:event, :message_received}
      assert_received {:event, :run_completed}
    end

    test "passes required_capabilities to start_run", %{store: store, adapter: adapter} do
      # Adapter has :tool and :sampling by default, so :tool should work
      {:ok, _result} =
        SessionManager.run_once(store, adapter, %{prompt: "Hello"},
          required_capabilities: [:tool]
        )

      assert MockAdapter.get_execute_count(adapter) == 1
    end

    test "rejects module store references that are not SessionStore servers", %{adapter: adapter} do
      assert {:error, %Error{code: :validation_error}} =
               SessionManager.run_once(SessionManager, adapter, %{prompt: "Hello"})

      assert {:error, %Error{code: :validation_error}} =
               SessionManager.run_once({SessionManager, :ignored}, adapter, %{prompt: "Hello"})
    end
  end

  # ============================================================================
  # execute_run/4 with event_callback Tests
  # ============================================================================

  describe "execute_run/4 with event_callback" do
    test "calls user event_callback with adapter events", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      test_pid = self()

      callback = fn event_data ->
        send(test_pid, {:user_event, event_data.type})
      end

      {:ok, _result} =
        SessionManager.execute_run(store, adapter, run.id, event_callback: callback)

      assert_received {:user_event, :run_started}
      assert_received {:user_event, :message_received}
      assert_received {:user_event, :run_completed}
    end

    test "persists events to store AND calls user callback", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      test_pid = self()

      callback = fn event_data ->
        send(test_pid, {:user_event, event_data.type})
      end

      {:ok, _result} =
        SessionManager.execute_run(store, adapter, run.id, event_callback: callback)

      # Verify events were persisted to store
      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)
      types = Enum.map(events, & &1.type)
      assert :run_started in types
      assert :message_received in types

      # Verify user callback was also called
      assert_received {:user_event, :run_started}
      assert_received {:user_event, :message_received}
    end

    test "works without event_callback (backward compat)", %{store: store, adapter: adapter} do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})

      # Call with no opts (arity 3 still works)
      {:ok, result} = SessionManager.execute_run(store, adapter, run.id)

      assert is_map(result.output)
    end
  end

  # ============================================================================
  # Adapter Timestamp and Metadata Persistence Tests
  # ============================================================================

  describe "adapter event timestamp and metadata persistence" do
    test "persists adapter-provided timestamp into Event.timestamp", %{
      store: store,
      adapter: adapter
    } do
      explicit_timestamp = ~U[2025-06-15 10:30:00Z]

      MockAdapter.set_response(adapter, :execute, %{
        content: "Response with explicit timestamp",
        token_usage: %{input_tokens: 5, output_tokens: 10},
        events: [
          %{
            type: :run_started,
            data: %{model: "mock-v1"},
            timestamp: explicit_timestamp
          },
          %{
            type: :message_received,
            data: %{content: "Response with explicit timestamp"},
            timestamp: explicit_timestamp
          },
          %{
            type: :run_completed,
            data: %{},
            timestamp: explicit_timestamp
          }
        ]
      })

      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)

      # Find adapter-emitted events (run_started, message_received, run_completed from adapter)
      adapter_events =
        Enum.filter(events, &(&1.type in [:run_started, :message_received, :run_completed]))

      assert adapter_events != []

      Enum.each(adapter_events, fn event ->
        assert event.timestamp == explicit_timestamp,
               "Expected adapter timestamp #{inspect(explicit_timestamp)} " <>
                 "but got #{inspect(event.timestamp)} for event type #{event.type}"
      end)
    end

    test "persists adapter-provided metadata into Event.metadata", %{
      store: store,
      adapter: adapter
    } do
      MockAdapter.set_response(adapter, :execute, %{
        content: "Response with metadata",
        token_usage: %{input_tokens: 5, output_tokens: 10},
        events: [
          %{
            type: :run_started,
            data: %{model: "mock-v1"},
            metadata: %{provider_event_id: "pe-123", latency_ms: 42}
          },
          %{
            type: :message_received,
            data: %{content: "Response with metadata"},
            metadata: %{chunk_count: 3}
          },
          %{
            type: :run_completed,
            data: %{}
          }
        ]
      })

      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)

      run_started = Enum.find(events, &(&1.type == :run_started))
      assert run_started != nil
      assert run_started.metadata[:provider_event_id] == "pe-123"
      assert run_started.metadata[:latency_ms] == 42

      message_received = Enum.find(events, &(&1.type == :message_received))
      assert message_received != nil
      assert message_received.metadata[:chunk_count] == 3
    end

    test "persists provider name in Event.metadata for adapter events", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)

      {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)

      adapter_events =
        Enum.filter(events, &(&1.type in [:run_started, :message_received, :run_completed]))

      assert adapter_events != []

      Enum.each(adapter_events, fn event ->
        assert event.metadata[:provider] == "mock",
               "Expected provider 'mock' in metadata for event type #{event.type}, " <>
                 "got metadata: #{inspect(event.metadata)}"
      end)
    end

    test "stream_session_events accepts and forwards wait_timeout_ms", %{
      store: store,
      adapter: adapter
    } do
      {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "test-agent"})
      {:ok, _} = SessionManager.activate_session(store, session.id)

      {:ok, cursor} = SessionStore.get_latest_sequence(store, session.id)
      test_pid = self()

      # Start stream with wait_timeout_ms — it should block instead of sleeping
      reader_task =
        Task.async(fn ->
          send(test_pid, :reader_started)

          SessionManager.stream_session_events(store, session.id,
            after: cursor,
            limit: 2,
            wait_timeout_ms: 10_000
          )
          |> Enum.take(2)
        end)

      assert_receive :reader_started, 1_000
      Process.sleep(50)

      # Execute a run — should produce events that unblock the stream
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, _} = SessionManager.execute_run(store, adapter, run.id)

      events = Task.await(reader_task, 10_000)
      assert length(events) == 2
      assert Enum.all?(events, &(&1.sequence_number > cursor))
    end
  end
end
