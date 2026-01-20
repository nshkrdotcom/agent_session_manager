defmodule AgentSessionManager.Test.MockProviderAdapter do
  @moduledoc """
  Comprehensive mock provider adapter for integration testing.

  This mock adapter supports:
  - Configurable execution behavior (success, failure, delays)
  - Event stream simulation with controllable timing
  - Capability advertisement
  - Cancellation and interrupt handling
  - Execution history tracking for assertions

  ## Usage

      {:ok, adapter} = MockProviderAdapter.start_link(
        capabilities: Fixtures.provider_capabilities(:full_claude),
        execution_mode: :streaming
      )

      # Configure response
      MockProviderAdapter.set_response(adapter, :execute, Fixtures.execution_result(:successful))

      # Execute and verify
      {:ok, result} = ProviderAdapter.execute(adapter, run, session)

      # Check execution history
      history = MockProviderAdapter.get_execution_history(adapter)

  ## Execution Modes

  - `:instant` - Returns immediately with configured result
  - `:streaming` - Simulates streaming with configurable chunk delay
  - `:delayed` - Adds configurable delay before response
  - `:failing` - Always returns configured error
  - `:timeout` - Simulates timeout (never returns)

  """

  @behaviour AgentSessionManager.Ports.ProviderAdapter

  use GenServer

  alias AgentSessionManager.Core.{Capability, Error}

  @type execution_mode :: :instant | :streaming | :delayed | :failing | :timeout

  @type state :: %{
          name: String.t(),
          capabilities: [Capability.t()],
          responses: map(),
          execution_mode: execution_mode(),
          delay_ms: non_neg_integer(),
          chunk_delay_ms: non_neg_integer(),
          fail_with: Error.t() | nil,
          execution_history: [map()],
          cancelled_runs: MapSet.t(),
          active_runs: map()
        }

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the mock provider adapter.

  ## Options

  - `:name` - Optional GenServer name
  - `:capabilities` - List of capabilities (default: minimal)
  - `:execution_mode` - Execution behavior (default: :instant)
  - `:delay_ms` - Delay in milliseconds for :delayed mode (default: 100)
  - `:chunk_delay_ms` - Delay between streaming chunks (default: 10)
  - `:fail_with` - Error to always return
  - `:provider_name` - Provider name string (default: "mock")
  - `:responses` - Map of response overrides

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc """
  Stops the mock adapter.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # ============================================================================
  # Configuration API
  # ============================================================================

  @doc """
  Sets the response for a specific operation.
  """
  @spec set_response(GenServer.server(), atom(), any()) :: :ok
  def set_response(server, operation, response) do
    GenServer.call(server, {:set_response, operation, response})
  end

  @doc """
  Sets the error to return for all operations.
  """
  @spec set_fail_with(GenServer.server(), Error.t()) :: :ok
  def set_fail_with(server, error) do
    GenServer.call(server, {:set_fail_with, error})
  end

  @doc """
  Clears the configured failure.
  """
  @spec clear_fail_with(GenServer.server()) :: :ok
  def clear_fail_with(server) do
    GenServer.call(server, :clear_fail_with)
  end

  @doc """
  Sets the execution mode.
  """
  @spec set_execution_mode(GenServer.server(), execution_mode()) :: :ok
  def set_execution_mode(server, mode) do
    GenServer.call(server, {:set_execution_mode, mode})
  end

  @doc """
  Sets the capabilities.
  """
  @spec set_capabilities(GenServer.server(), [Capability.t()]) :: :ok
  def set_capabilities(server, capabilities) do
    GenServer.call(server, {:set_capabilities, capabilities})
  end

  # ============================================================================
  # Query API
  # ============================================================================

  @doc """
  Gets the execution history.
  """
  @spec get_execution_history(GenServer.server()) :: [map()]
  def get_execution_history(server) do
    GenServer.call(server, :get_execution_history)
  end

  @doc """
  Clears the execution history.
  """
  @spec clear_execution_history(GenServer.server()) :: :ok
  def clear_execution_history(server) do
    GenServer.call(server, :clear_execution_history)
  end

  @doc """
  Gets the list of cancelled run IDs.
  """
  @spec get_cancelled_runs(GenServer.server()) :: [String.t()]
  def get_cancelled_runs(server) do
    GenServer.call(server, :get_cancelled_runs)
  end

  @doc """
  Gets the current state (for debugging).
  """
  @spec get_state(GenServer.server()) :: state()
  def get_state(server) do
    GenServer.call(server, :get_state)
  end

  # ============================================================================
  # ProviderAdapter Behaviour Implementation
  # ============================================================================

  @impl AgentSessionManager.Ports.ProviderAdapter
  def name(adapter) do
    GenServer.call(adapter, :name)
  end

  @impl AgentSessionManager.Ports.ProviderAdapter
  def capabilities(adapter) do
    GenServer.call(adapter, :capabilities)
  end

  @impl AgentSessionManager.Ports.ProviderAdapter
  def execute(adapter, run, session, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 60_000)
    GenServer.call(adapter, {:execute, run, session, opts}, timeout + 5_000)
  end

  @impl AgentSessionManager.Ports.ProviderAdapter
  def cancel(adapter, run_id) do
    GenServer.call(adapter, {:cancel, run_id})
  end

  @impl AgentSessionManager.Ports.ProviderAdapter
  def validate_config(_adapter, config) do
    # Basic validation - just check it's a map
    if is_map(config), do: :ok, else: {:error, Error.new(:validation_error, "Invalid config")}
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl GenServer
  def init(opts) do
    state = %{
      name: Keyword.get(opts, :provider_name, "mock"),
      capabilities: Keyword.get(opts, :capabilities, default_capabilities()),
      responses: Keyword.get(opts, :responses, %{}),
      execution_mode: Keyword.get(opts, :execution_mode, :instant),
      delay_ms: Keyword.get(opts, :delay_ms, 100),
      chunk_delay_ms: Keyword.get(opts, :chunk_delay_ms, 10),
      fail_with: Keyword.get(opts, :fail_with),
      execution_history: [],
      cancelled_runs: MapSet.new(),
      active_runs: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:name, _from, state) do
    {:reply, state.name, state}
  end

  def handle_call(:capabilities, _from, state) do
    result =
      case state.fail_with do
        nil -> {:ok, state.capabilities}
        error -> {:error, error}
      end

    {:reply, result, state}
  end

  def handle_call({:execute, run, session, opts}, from, state) do
    # Record execution in history
    history_entry = %{
      run_id: run.id,
      session_id: session.id,
      input: run.input,
      timestamp: DateTime.utc_now()
    }

    state = %{state | execution_history: state.execution_history ++ [history_entry]}

    # Track active run
    state = %{state | active_runs: Map.put(state.active_runs, run.id, %{from: from})}

    # Check for configured failure
    case state.fail_with do
      nil ->
        # Execute based on mode
        execute_with_mode(state, run, session, opts, from)

      error ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:cancel, run_id}, _from, state) do
    state = %{state | cancelled_runs: MapSet.put(state.cancelled_runs, run_id)}

    # If run is active, remove it
    state = %{state | active_runs: Map.delete(state.active_runs, run_id)}

    {:reply, {:ok, run_id}, state}
  end

  def handle_call({:set_response, operation, response}, _from, state) do
    state = %{state | responses: Map.put(state.responses, operation, response)}
    {:reply, :ok, state}
  end

  def handle_call({:set_fail_with, error}, _from, state) do
    {:reply, :ok, %{state | fail_with: error}}
  end

  def handle_call(:clear_fail_with, _from, state) do
    {:reply, :ok, %{state | fail_with: nil}}
  end

  def handle_call({:set_execution_mode, mode}, _from, state) do
    {:reply, :ok, %{state | execution_mode: mode}}
  end

  def handle_call({:set_capabilities, capabilities}, _from, state) do
    {:reply, :ok, %{state | capabilities: capabilities}}
  end

  def handle_call(:get_execution_history, _from, state) do
    {:reply, state.execution_history, state}
  end

  def handle_call(:clear_execution_history, _from, state) do
    {:reply, :ok, %{state | execution_history: []}}
  end

  def handle_call(:get_cancelled_runs, _from, state) do
    {:reply, MapSet.to_list(state.cancelled_runs), state}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  def handle_call({:validate_config, config}, _from, state) do
    result = if is_map(config), do: :ok, else: {:error, Error.new(:validation_error, "Invalid")}
    {:reply, result, state}
  end

  @impl GenServer
  def handle_info({:delayed_reply, run_id, result}, state) do
    case Map.get(state.active_runs, run_id) do
      %{from: from} ->
        GenServer.reply(from, result)
        state = %{state | active_runs: Map.delete(state.active_runs, run_id)}
        {:noreply, state}

      nil ->
        # Run was cancelled, ignore
        {:noreply, state}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp execute_with_mode(state, run, session, opts, from) do
    case state.execution_mode do
      :instant ->
        result = build_result(state, run, session, opts)
        {:reply, result, %{state | active_runs: Map.delete(state.active_runs, run.id)}}

      :streaming ->
        # Execute streaming in background
        spawn_link(fn ->
          execute_streaming(state, run, session, opts, from)
        end)

        {:noreply, state}

      :delayed ->
        # Schedule delayed reply
        Process.send_after(
          self(),
          {:delayed_reply, run.id, build_result(state, run, session, opts)},
          state.delay_ms
        )

        {:noreply, state}

      :failing ->
        error = state.fail_with || Error.new(:provider_error, "Configured to fail")
        {:reply, {:error, error}, state}

      :timeout ->
        # Never reply - simulate timeout
        {:noreply, state}
    end
  end

  defp execute_streaming(state, run, session, opts, from) do
    event_callback = Keyword.get(opts, :event_callback)

    # Get configured response or default
    response = Map.get(state.responses, :execute, default_response())

    # Emit run_started
    emit_event(event_callback, :run_started, run, session, %{
      model: "mock-model"
    })

    Process.sleep(state.chunk_delay_ms)

    # Check if cancelled
    if MapSet.member?(state.cancelled_runs, run.id) do
      emit_event(event_callback, :run_cancelled, run, session, %{})
      GenServer.reply(from, {:error, Error.new(:cancelled, "Run was cancelled")})
    else
      # Emit streaming chunks
      content = response.output.content || ""
      chunks = chunk_string(content, 10)

      for {chunk, _idx} <- Enum.with_index(chunks) do
        emit_event(event_callback, :message_streamed, run, session, %{
          content: chunk,
          delta: chunk
        })

        Process.sleep(state.chunk_delay_ms)
      end

      # Emit message_received
      emit_event(event_callback, :message_received, run, session, %{
        content: content,
        role: "assistant"
      })

      # Emit token_usage_updated
      emit_event(event_callback, :token_usage_updated, run, session, response.token_usage)

      # Emit run_completed
      emit_event(event_callback, :run_completed, run, session, %{
        stop_reason: response.output[:stop_reason] || "end_turn"
      })

      GenServer.reply(from, {:ok, response})
    end
  end

  defp emit_event(nil, _type, _run, _session, _data), do: :ok

  defp emit_event(callback, type, run, session, data) when is_function(callback) do
    event = %{
      type: type,
      timestamp: DateTime.utc_now(),
      session_id: session.id,
      run_id: run.id,
      data: data,
      provider: :mock
    }

    callback.(event)
  end

  defp build_result(state, run, session, opts) do
    event_callback = Keyword.get(opts, :event_callback)
    response = Map.get(state.responses, :execute, default_response())

    # Emit events if callback provided
    if event_callback do
      emit_event(event_callback, :run_started, run, session, %{model: "mock-model"})

      emit_event(event_callback, :message_received, run, session, %{
        content: response.output.content,
        role: "assistant"
      })

      emit_event(event_callback, :run_completed, run, session, %{
        stop_reason: response.output[:stop_reason] || "end_turn"
      })
    end

    {:ok, response}
  end

  defp default_response do
    %{
      output: %{
        content: "Mock response",
        stop_reason: "end_turn",
        tool_calls: []
      },
      token_usage: %{
        input_tokens: 10,
        output_tokens: 20
      },
      events: []
    }
  end

  defp default_capabilities do
    [
      %Capability{name: "chat", type: :tool, enabled: true},
      %Capability{name: "sampling", type: :sampling, enabled: true}
    ]
  end

  defp chunk_string(string, chunk_size) do
    string
    |> String.graphemes()
    |> Enum.chunk_every(chunk_size)
    |> Enum.map(&Enum.join/1)
  end
end
