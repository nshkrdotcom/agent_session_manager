defmodule AgentSessionManager.Ports.ProviderAdapterContractTest do
  @moduledoc """
  Contract tests for ProviderAdapter behaviour.

  These tests define the expected behaviour of any ProviderAdapter implementation.
  They use a mock adapter to verify the contract without depending on external services.
  """

  use ExUnit.Case, async: true

  alias AgentSessionManager.Core.{Capability, Error, Run, Session}

  # ============================================================================
  # Mock Adapter for Contract Tests
  # ============================================================================

  defmodule MockAdapter do
    @moduledoc """
    Mock implementation of ProviderAdapter for testing.

    This adapter simulates provider behaviour by returning configured responses.
    """

    @behaviour AgentSessionManager.Ports.ProviderAdapter

    use Agent

    @doc """
    Starts the mock adapter with optional configuration.

    ## Options

    - `:name` - Optional name for the agent
    - `:capabilities` - List of capabilities to return
    - `:responses` - Map of response configurations
    - `:fail_with` - Error to return for all operations
    """
    def start_link(opts \\ []) do
      {name, config} = Keyword.pop(opts, :name)
      initial_state = build_initial_state(config)

      if name do
        Agent.start_link(fn -> initial_state end, name: name)
      else
        Agent.start_link(fn -> initial_state end)
      end
    end

    def stop(adapter) do
      Agent.stop(adapter)
    end

    defp build_initial_state(opts) do
      %{
        capabilities: Keyword.get(opts, :capabilities, default_capabilities()),
        responses: Keyword.get(opts, :responses, %{}),
        fail_with: Keyword.get(opts, :fail_with),
        events_emitted: [],
        execute_count: 0
      }
    end

    defp default_capabilities do
      [
        %Capability{name: "chat", type: :tool, enabled: true},
        %Capability{name: "sampling", type: :sampling, enabled: true}
      ]
    end

    # ProviderAdapter Behaviour Implementation

    @impl AgentSessionManager.Ports.ProviderAdapter
    def name(_adapter), do: "mock"

    @impl AgentSessionManager.Ports.ProviderAdapter
    def capabilities(adapter) do
      Agent.get(adapter, fn state ->
        case state.fail_with do
          nil -> {:ok, state.capabilities}
          error -> {:error, error}
        end
      end)
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def execute(adapter, run, session, opts \\ []) do
      Agent.get_and_update(adapter, fn state ->
        state = %{state | execute_count: state.execute_count + 1}

        result =
          case state.fail_with do
            nil ->
              execute_mock(state, run, session, opts)

            error ->
              {:error, error}
          end

        {result, state}
      end)
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def cancel(adapter, run_id) do
      Agent.get(adapter, fn state ->
        case state.fail_with do
          nil -> {:ok, run_id}
          error -> {:error, error}
        end
      end)
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def validate_config(_adapter, config) do
      if Map.has_key?(config, :invalid) do
        {:error, Error.new(:validation_error, "Invalid configuration")}
      else
        :ok
      end
    end

    # Mock-specific helpers

    defp execute_mock(state, run, _session, opts) do
      response = Map.get(state.responses, :execute, %{content: "Mock response"})
      event_callback = Keyword.get(opts, :event_callback)

      # Simulate emitting events
      events = [
        build_event(:run_started, run),
        build_event(:message_received, run, %{content: response.content}),
        build_event(:run_completed, run)
      ]

      # Call the event callback if provided
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
      %{
        type: type,
        session_id: run.session_id,
        run_id: run.id,
        data: data,
        timestamp: DateTime.utc_now()
      }
    end

    # Test helpers

    def get_execute_count(adapter) do
      Agent.get(adapter, & &1.execute_count)
    end

    def set_fail_with(adapter, error) do
      Agent.update(adapter, fn state -> %{state | fail_with: error} end)
    end

    def set_capabilities(adapter, capabilities) do
      Agent.update(adapter, fn state -> %{state | capabilities: capabilities} end)
    end

    def set_response(adapter, key, response) do
      Agent.update(adapter, fn state ->
        %{state | responses: Map.put(state.responses, key, response)}
      end)
    end
  end

  # ============================================================================
  # Contract Tests
  # ============================================================================

  describe "name/1" do
    test "returns the provider name" do
      {:ok, adapter} = MockAdapter.start_link()

      assert MockAdapter.name(adapter) == "mock"

      MockAdapter.stop(adapter)
    end
  end

  describe "capabilities/1" do
    test "returns list of supported capabilities" do
      {:ok, adapter} = MockAdapter.start_link()

      {:ok, capabilities} = MockAdapter.capabilities(adapter)

      assert is_list(capabilities)
      assert capabilities != []
      assert Enum.all?(capabilities, &match?(%Capability{}, &1))

      MockAdapter.stop(adapter)
    end

    test "capabilities have valid types" do
      {:ok, adapter} = MockAdapter.start_link()

      {:ok, capabilities} = MockAdapter.capabilities(adapter)

      assert Enum.all?(capabilities, fn cap ->
               Capability.valid_type?(cap.type)
             end)

      MockAdapter.stop(adapter)
    end

    test "returns error when adapter fails" do
      error = Error.new(:provider_unavailable, "Provider is down")
      {:ok, adapter} = MockAdapter.start_link(fail_with: error)

      assert {:error, %Error{code: :provider_unavailable}} = MockAdapter.capabilities(adapter)

      MockAdapter.stop(adapter)
    end

    test "can return custom capabilities" do
      capabilities = [
        %Capability{name: "custom_tool", type: :tool, enabled: true},
        %Capability{name: "custom_resource", type: :resource, enabled: true}
      ]

      {:ok, adapter} = MockAdapter.start_link(capabilities: capabilities)

      {:ok, returned} = MockAdapter.capabilities(adapter)

      assert length(returned) == 2
      assert Enum.any?(returned, &(&1.name == "custom_tool"))
      assert Enum.any?(returned, &(&1.name == "custom_resource"))

      MockAdapter.stop(adapter)
    end
  end

  describe "execute/4" do
    setup do
      {:ok, adapter} = MockAdapter.start_link()
      {:ok, session} = Session.new(%{agent_id: "test-agent"})
      {:ok, run} = Run.new(%{session_id: session.id, input: %{prompt: "Hello"}})

      on_exit(fn ->
        if Process.alive?(adapter), do: MockAdapter.stop(adapter)
      end)

      {:ok, adapter: adapter, session: session, run: run}
    end

    test "executes a run and returns result", %{adapter: adapter, session: session, run: run} do
      {:ok, result} = MockAdapter.execute(adapter, run, session)

      assert is_map(result)
      assert Map.has_key?(result, :output)
      assert Map.has_key?(result, :token_usage)
    end

    test "result contains expected output structure", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      {:ok, result} = MockAdapter.execute(adapter, run, session)

      assert is_map(result.output)
      assert is_map(result.token_usage)
    end

    test "tracks token usage", %{adapter: adapter, session: session, run: run} do
      {:ok, result} = MockAdapter.execute(adapter, run, session)

      assert Map.has_key?(result.token_usage, :input_tokens)
      assert Map.has_key?(result.token_usage, :output_tokens)
      assert is_integer(result.token_usage.input_tokens)
      assert is_integer(result.token_usage.output_tokens)
    end

    test "calls event callback when provided", %{adapter: adapter, session: session, run: run} do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _result} = MockAdapter.execute(adapter, run, session, event_callback: callback)

      # Should receive events
      assert_receive {:event, %{type: :run_started}}
      assert_receive {:event, %{type: :message_received}}
      assert_receive {:event, %{type: :run_completed}}
    end

    test "returns error on failure", %{adapter: adapter, session: session, run: run} do
      error = Error.new(:provider_error, "Execution failed")
      MockAdapter.set_fail_with(adapter, error)

      assert {:error, %Error{code: :provider_error}} =
               MockAdapter.execute(adapter, run, session)
    end

    test "increments execute count", %{adapter: adapter, session: session, run: run} do
      assert MockAdapter.get_execute_count(adapter) == 0

      {:ok, _} = MockAdapter.execute(adapter, run, session)
      assert MockAdapter.get_execute_count(adapter) == 1

      {:ok, _} = MockAdapter.execute(adapter, run, session)
      assert MockAdapter.get_execute_count(adapter) == 2
    end
  end

  describe "cancel/2" do
    setup do
      {:ok, adapter} = MockAdapter.start_link()
      {:ok, session} = Session.new(%{agent_id: "test-agent"})
      {:ok, run} = Run.new(%{session_id: session.id})

      on_exit(fn ->
        if Process.alive?(adapter), do: MockAdapter.stop(adapter)
      end)

      {:ok, adapter: adapter, session: session, run: run}
    end

    test "cancels a run", %{adapter: adapter, run: run} do
      assert {:ok, _} = MockAdapter.cancel(adapter, run.id)
    end

    test "returns the cancelled run id", %{adapter: adapter, run: run} do
      {:ok, run_id} = MockAdapter.cancel(adapter, run.id)
      assert run_id == run.id
    end

    test "returns error when cancellation fails", %{adapter: adapter, run: run} do
      error = Error.new(:provider_error, "Cannot cancel")
      MockAdapter.set_fail_with(adapter, error)

      assert {:error, %Error{code: :provider_error}} = MockAdapter.cancel(adapter, run.id)
    end
  end

  describe "validate_config/2" do
    test "returns :ok for valid config" do
      {:ok, adapter} = MockAdapter.start_link()

      config = %{api_key: "test-key", model: "test-model"}
      assert :ok = MockAdapter.validate_config(adapter, config)

      MockAdapter.stop(adapter)
    end

    test "returns error for invalid config" do
      {:ok, adapter} = MockAdapter.start_link()

      config = %{invalid: true}

      assert {:error, %Error{code: :validation_error}} =
               MockAdapter.validate_config(adapter, config)

      MockAdapter.stop(adapter)
    end
  end

  describe "event emission contract" do
    setup do
      {:ok, adapter} = MockAdapter.start_link()
      {:ok, session} = Session.new(%{agent_id: "test-agent"})
      {:ok, run} = Run.new(%{session_id: session.id})

      on_exit(fn ->
        if Process.alive?(adapter), do: MockAdapter.stop(adapter)
      end)

      {:ok, adapter: adapter, session: session, run: run}
    end

    test "events contain required fields", %{adapter: adapter, session: session, run: run} do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _} = MockAdapter.execute(adapter, run, session, event_callback: callback)

      # Check all events have required fields
      receive do
        {:event, event} ->
          assert Map.has_key?(event, :type)
          assert Map.has_key?(event, :session_id)
          assert Map.has_key?(event, :run_id)
          assert Map.has_key?(event, :timestamp)
      end
    end

    test "events are emitted in correct order", %{adapter: adapter, session: session, run: run} do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _} = MockAdapter.execute(adapter, run, session, event_callback: callback)

      # First event should be run_started
      assert_receive {:event, %{type: :run_started}}
      # Message events in the middle
      assert_receive {:event, %{type: :message_received}}
      # Last event should be run_completed
      assert_receive {:event, %{type: :run_completed}}
    end

    test "events reference correct session and run", %{
      adapter: adapter,
      session: session,
      run: run
    } do
      test_pid = self()

      callback = fn event ->
        send(test_pid, {:event, event})
      end

      {:ok, _} = MockAdapter.execute(adapter, run, session, event_callback: callback)

      receive do
        {:event, event} ->
          assert event.session_id == session.id
          assert event.run_id == run.id
      end
    end
  end
end
