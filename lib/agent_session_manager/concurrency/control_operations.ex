defmodule AgentSessionManager.Concurrency.ControlOperations do
  @moduledoc """
  Manages control operations (interrupt, cancel, pause, resume) for runs.

  This module provides a centralized way to manage control operations across
  different adapters. It handles:

  - Interrupt: Immediately stop a running operation
  - Cancel: Permanently cancel an operation (terminal state)
  - Pause: Temporarily pause an operation (requires capability)
  - Resume: Resume a paused operation (requires capability)

  ## Idempotency

  All control operations are idempotent:
  - Interrupting an already interrupted run succeeds
  - Cancelling an already cancelled run succeeds
  - Pausing an already paused run succeeds
  - Resuming an already running run succeeds

  ## Capability Checking

  Pause and resume operations require the adapter to support these capabilities.
  If the adapter doesn't have the required capability, an error is returned.

  ## Terminal States

  Once a run enters a terminal state (:cancelled, :completed, :failed), it
  cannot be resumed or have further operations performed on it.

  ## Usage

      {:ok, ops} = ControlOperations.start_link(adapter: adapter)

      # Interrupt a running operation
      {:ok, run_id} = ControlOperations.interrupt(ops, run_id)

      # Cancel an operation (terminal)
      {:ok, run_id} = ControlOperations.cancel(ops, run_id)

      # Pause (if supported)
      {:ok, run_id} = ControlOperations.pause(ops, run_id)

      # Resume (if supported)
      {:ok, run_id} = ControlOperations.resume(ops, run_id)

  """

  use GenServer

  alias AgentSessionManager.Core.Error

  @terminal_states [:cancelled, :completed, :failed, :timeout]

  @type operation :: :interrupt | :cancel | :pause | :resume

  @type operation_record :: %{
          operation: operation(),
          timestamp: DateTime.t(),
          result: :ok | {:error, Error.t()}
        }

  @type operation_status :: %{
          last_operation: operation() | nil,
          state: atom(),
          history: [operation_record()]
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the control operations manager.

  ## Options

  - `:adapter` - The provider adapter to use for operations (required)
  - `:name` - Optional GenServer name

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
  Interrupts a running operation.

  This is an idempotent operation - interrupting an already interrupted
  run will succeed.

  ## Returns

  - `{:ok, run_id}` - Interrupt succeeded
  - `{:error, Error.t()}` - Interrupt failed

  """
  @spec interrupt(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def interrupt(server, run_id) do
    GenServer.call(server, {:interrupt, run_id})
  end

  @doc """
  Cancels an operation.

  This is an idempotent operation - cancelling an already cancelled run
  will succeed. Cancel is a terminal operation - the run cannot be resumed.

  ## Returns

  - `{:ok, run_id}` - Cancel succeeded
  - `{:error, Error.t()}` - Cancel failed

  """
  @spec cancel(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def cancel(server, run_id) do
    GenServer.call(server, {:cancel, run_id})
  end

  @doc """
  Pauses a running operation.

  This is an idempotent operation - pausing an already paused run will
  succeed. Requires the adapter to have the "pause" capability.

  ## Returns

  - `{:ok, run_id}` - Pause succeeded
  - `{:error, %Error{code: :capability_not_supported}}` - Adapter doesn't support pause
  - `{:error, Error.t()}` - Pause failed

  """
  @spec pause(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def pause(server, run_id) do
    GenServer.call(server, {:pause, run_id})
  end

  @doc """
  Resumes a paused operation.

  This is an idempotent operation - resuming an already running run will
  succeed. Requires the adapter to have the "resume" capability.
  Cannot resume a run in a terminal state.

  ## Returns

  - `{:ok, run_id}` - Resume succeeded
  - `{:error, %Error{code: :capability_not_supported}}` - Adapter doesn't support resume
  - `{:error, %Error{code: :invalid_operation}}` - Run is in a terminal state
  - `{:error, Error.t()}` - Resume failed

  """
  @spec resume(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def resume(server, run_id) do
    GenServer.call(server, {:resume, run_id})
  end

  @doc """
  Cancels multiple runs at once.

  Returns a map of run_id => :ok | {:error, Error.t()}.
  """
  @spec cancel_all(GenServer.server(), [String.t()]) :: %{String.t() => :ok | {:error, Error.t()}}
  def cancel_all(server, run_ids) do
    GenServer.call(server, {:cancel_all, run_ids})
  end

  @doc """
  Interrupts all runs for a given session.

  Returns a map of run_id => :ok | {:error, Error.t()}.
  """
  @spec interrupt_session(GenServer.server(), String.t()) :: %{
          String.t() => :ok | {:error, Error.t()}
        }
  def interrupt_session(server, session_id) do
    GenServer.call(server, {:interrupt_session, session_id})
  end

  @doc """
  Registers a run as belonging to a session.

  This is used for session-level operations like interrupt_session.
  """
  @spec register_run(GenServer.server(), String.t(), String.t()) :: :ok
  def register_run(server, session_id, run_id) do
    GenServer.call(server, {:register_run, session_id, run_id})
  end

  @doc """
  Gets the operation status for a run.
  """
  @spec get_operation_status(GenServer.server(), String.t()) :: operation_status()
  def get_operation_status(server, run_id) do
    GenServer.call(server, {:get_operation_status, run_id})
  end

  @doc """
  Gets the full operation history for a run.
  """
  @spec get_operation_history(GenServer.server(), String.t()) :: [operation_record()]
  def get_operation_history(server, run_id) do
    GenServer.call(server, {:get_operation_history, run_id})
  end

  @doc """
  Checks if a state is a terminal state.

  Terminal states are: :cancelled, :completed, :failed, :timeout
  """
  @spec is_terminal_state?(atom()) :: boolean()
  def is_terminal_state?(state) do
    state in @terminal_states
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(opts) do
    adapter = Keyword.fetch!(opts, :adapter)

    state = %{
      adapter: adapter,
      # Map of run_id => operation state
      run_states: %{},
      # Map of run_id => [operation_record]
      run_history: %{},
      # Map of session_id => MapSet of run_ids
      session_runs: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:interrupt, run_id}, _from, state) do
    {result, new_state} = do_interrupt(run_id, state)
    {:reply, result, new_state}
  end

  def handle_call({:cancel, run_id}, _from, state) do
    {result, new_state} = do_cancel(run_id, state)
    {:reply, result, new_state}
  end

  def handle_call({:pause, run_id}, _from, state) do
    {result, new_state} = do_pause(run_id, state)
    {:reply, result, new_state}
  end

  def handle_call({:resume, run_id}, _from, state) do
    {result, new_state} = do_resume(run_id, state)
    {:reply, result, new_state}
  end

  def handle_call({:cancel_all, run_ids}, _from, state) do
    {results, new_state} =
      Enum.reduce(run_ids, {%{}, state}, fn run_id, {results, acc_state} ->
        {result, updated_state} = do_cancel(run_id, acc_state)
        result_value = if match?({:ok, _}, result), do: :ok, else: result
        {Map.put(results, run_id, result_value), updated_state}
      end)

    {:reply, results, new_state}
  end

  def handle_call({:interrupt_session, session_id}, _from, state) do
    run_ids = Map.get(state.session_runs, session_id, MapSet.new()) |> MapSet.to_list()

    {results, new_state} =
      Enum.reduce(run_ids, {%{}, state}, fn run_id, {results, acc_state} ->
        {result, updated_state} = do_interrupt(run_id, acc_state)
        result_value = if match?({:ok, _}, result), do: :ok, else: result
        {Map.put(results, run_id, result_value), updated_state}
      end)

    {:reply, results, new_state}
  end

  def handle_call({:register_run, session_id, run_id}, _from, state) do
    session_runs = Map.get(state.session_runs, session_id, MapSet.new())
    new_session_runs = Map.put(state.session_runs, session_id, MapSet.put(session_runs, run_id))
    {:reply, :ok, %{state | session_runs: new_session_runs}}
  end

  def handle_call({:get_operation_status, run_id}, _from, state) do
    history = Map.get(state.run_history, run_id, [])
    run_state = Map.get(state.run_states, run_id, :unknown)

    last_operation =
      case history do
        [] -> nil
        list -> List.last(list).operation
      end

    status = %{
      last_operation: last_operation,
      state: run_state,
      history: history
    }

    {:reply, status, state}
  end

  def handle_call({:get_operation_history, run_id}, _from, state) do
    history = Map.get(state.run_history, run_id, [])
    {:reply, history, state}
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp do_interrupt(run_id, state) do
    # Check if already in terminal state - if so, just return success (idempotent)
    current_state = Map.get(state.run_states, run_id)

    if current_state == :interrupted do
      # Already interrupted, return success (idempotent)
      {{:ok, run_id}, state}
    else
      # Call adapter to interrupt
      case call_adapter_interrupt(state.adapter, run_id) do
        {:ok, _} ->
          new_state = record_operation(state, run_id, :interrupt, :ok, :interrupted)
          {{:ok, run_id}, new_state}

        {:error, error} ->
          new_state = record_operation(state, run_id, :interrupt, {:error, error}, nil)
          {{:error, error}, new_state}
      end
    end
  end

  defp do_cancel(run_id, state) do
    current_state = Map.get(state.run_states, run_id)

    if current_state == :cancelled do
      # Already cancelled, return success (idempotent)
      {{:ok, run_id}, state}
    else
      # Call adapter to cancel
      case call_adapter_cancel(state.adapter, run_id) do
        {:ok, _} ->
          new_state = record_operation(state, run_id, :cancel, :ok, :cancelled)
          {{:ok, run_id}, new_state}

        {:error, error} ->
          new_state = record_operation(state, run_id, :cancel, {:error, error}, nil)
          {{:error, error}, new_state}
      end
    end
  end

  defp do_pause(run_id, state) do
    current_state = Map.get(state.run_states, run_id)

    if current_state == :paused do
      # Already paused, return success (idempotent)
      {{:ok, run_id}, state}
    else
      # Check capability
      case check_capability(state.adapter, "pause") do
        :ok ->
          case call_adapter_pause(state.adapter, run_id) do
            {:ok, _} ->
              new_state = record_operation(state, run_id, :pause, :ok, :paused)
              {{:ok, run_id}, new_state}

            {:error, error} ->
              new_state = record_operation(state, run_id, :pause, {:error, error}, nil)
              {{:error, error}, new_state}
          end

        {:error, error} ->
          {{:error, error}, state}
      end
    end
  end

  defp do_resume(run_id, state) do
    current_state = Map.get(state.run_states, run_id)

    cond do
      current_state == :running ->
        # Already running, return success (idempotent)
        {{:ok, run_id}, state}

      current_state in @terminal_states ->
        # Cannot resume from terminal state
        error =
          Error.new(:invalid_operation, "Cannot resume run in terminal state: #{current_state}")

        {{:error, error}, state}

      true ->
        # Check capability
        case check_capability(state.adapter, "resume") do
          :ok ->
            case call_adapter_resume(state.adapter, run_id) do
              {:ok, _} ->
                new_state = record_operation(state, run_id, :resume, :ok, :running)
                {{:ok, run_id}, new_state}

              {:error, error} ->
                new_state = record_operation(state, run_id, :resume, {:error, error}, nil)
                {{:error, error}, new_state}
            end

          {:error, error} ->
            {{:error, error}, state}
        end
    end
  end

  defp record_operation(state, run_id, operation, result, new_run_state) do
    record = %{
      operation: operation,
      timestamp: DateTime.utc_now(),
      result: result
    }

    history = Map.get(state.run_history, run_id, [])
    new_history = history ++ [record]

    new_state = %{state | run_history: Map.put(state.run_history, run_id, new_history)}

    if new_run_state do
      %{new_state | run_states: Map.put(new_state.run_states, run_id, new_run_state)}
    else
      new_state
    end
  end

  defp check_capability(adapter, capability_name) do
    case get_capabilities(adapter) do
      {:ok, capabilities} ->
        if Enum.any?(capabilities, fn cap ->
             cap.name == capability_name && cap.enabled
           end) do
          :ok
        else
          {:error,
           Error.new(
             :capability_not_supported,
             "Capability '#{capability_name}' not supported by adapter"
           )}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp get_capabilities(adapter) do
    # Try to get capabilities from adapter
    if function_exported?(adapter.__struct__, :capabilities, 1) do
      adapter.__struct__.capabilities(adapter)
    else
      GenServer.call(adapter, :capabilities)
    end
  rescue
    _ -> GenServer.call(adapter, :capabilities)
  end

  defp call_adapter_interrupt(adapter, run_id) do
    # Try using the module function first
    if function_exported?(adapter.__struct__, :interrupt, 2) do
      adapter.__struct__.interrupt(adapter, run_id)
    else
      # Fall back to GenServer call
      GenServer.call(adapter, {:interrupt, run_id})
    end
  rescue
    _ -> GenServer.call(adapter, {:interrupt, run_id})
  end

  defp call_adapter_cancel(adapter, run_id) do
    if function_exported?(adapter.__struct__, :cancel, 2) do
      adapter.__struct__.cancel(adapter, run_id)
    else
      GenServer.call(adapter, {:cancel, run_id})
    end
  rescue
    _ -> GenServer.call(adapter, {:cancel, run_id})
  end

  defp call_adapter_pause(adapter, run_id) do
    if function_exported?(adapter.__struct__, :pause, 2) do
      adapter.__struct__.pause(adapter, run_id)
    else
      GenServer.call(adapter, {:pause, run_id})
    end
  rescue
    _ -> GenServer.call(adapter, {:pause, run_id})
  end

  defp call_adapter_resume(adapter, run_id) do
    if function_exported?(adapter.__struct__, :resume, 2) do
      adapter.__struct__.resume(adapter, run_id)
    else
      GenServer.call(adapter, {:resume, run_id})
    end
  rescue
    _ -> GenServer.call(adapter, {:resume, run_id})
  end
end
