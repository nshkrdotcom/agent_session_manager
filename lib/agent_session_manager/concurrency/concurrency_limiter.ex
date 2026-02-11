defmodule AgentSessionManager.Concurrency.ConcurrencyLimiter do
  @moduledoc """
  Enforces concurrency limits for sessions and runs.

  This module provides centralized tracking and enforcement of concurrency
  limits across the session manager. It ensures that:

  - The maximum number of parallel sessions is not exceeded
  - The maximum number of parallel runs (across all sessions) is not exceeded
  - Resources are properly released when sessions/runs complete

  ## Configuration

  - `:max_parallel_sessions` - Maximum concurrent sessions (default: 100, or :infinity)
  - `:max_parallel_runs` - Maximum concurrent runs globally (default: 50, or :infinity)

  ## Design

  The limiter uses a GenServer with ETS tables for efficient concurrent reads.
  All write operations (acquire/release) go through the GenServer to ensure
  consistency. Read operations (status checks) can be done directly from ETS.

  ## Idempotency

  All operations are idempotent:
  - Acquiring the same session/run multiple times only counts once
  - Releasing a non-existent session/run is a no-op

  ## Usage

      {:ok, limiter} = ConcurrencyLimiter.start_link(
        max_parallel_sessions: 10,
        max_parallel_runs: 20
      )

      # Acquire slots before starting sessions/runs
      :ok = ConcurrencyLimiter.acquire_session_slot(limiter, session_id)
      :ok = ConcurrencyLimiter.acquire_run_slot(limiter, session_id, run_id)

      # Release when done
      :ok = ConcurrencyLimiter.release_run_slot(limiter, run_id)
      :ok = ConcurrencyLimiter.release_session_slot(limiter, session_id)

  """

  use GenServer

  alias AgentSessionManager.Config
  alias AgentSessionManager.Core.Error

  @type limits :: %{
          max_parallel_sessions: pos_integer() | :infinity,
          max_parallel_runs: pos_integer() | :infinity
        }

  @type status :: %{
          active_sessions: non_neg_integer(),
          active_runs: non_neg_integer(),
          max_parallel_sessions: pos_integer() | :infinity,
          max_parallel_runs: pos_integer() | :infinity,
          available_session_slots: non_neg_integer() | :infinity,
          available_run_slots: non_neg_integer() | :infinity
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the concurrency limiter.

  ## Options

  - `:max_parallel_sessions` - Maximum concurrent sessions (default: `100`)
  - `:max_parallel_runs` - Maximum concurrent runs (default: `50`)
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
  Gets the configured limits.
  """
  @spec get_limits(GenServer.server()) :: limits()
  def get_limits(limiter) do
    GenServer.call(limiter, :get_limits)
  end

  @doc """
  Gets the current status including active counts and available capacity.
  """
  @spec get_status(GenServer.server()) :: status()
  def get_status(limiter) do
    GenServer.call(limiter, :get_status)
  end

  @doc """
  Attempts to acquire a session slot.

  Returns `:ok` if successful, or an error if the limit would be exceeded.

  This operation is idempotent - acquiring the same session_id multiple times
  only counts as one slot.

  ## Parameters

  - `limiter` - The limiter server
  - `session_id` - The session identifier

  ## Returns

  - `:ok` - Session slot acquired
  - `{:error, %Error{code: :max_sessions_exceeded}}` - Limit exceeded

  """
  @spec acquire_session_slot(GenServer.server(), String.t()) :: :ok | {:error, Error.t()}
  def acquire_session_slot(limiter, session_id) do
    GenServer.call(limiter, {:acquire_session, session_id})
  end

  @doc """
  Releases a session slot.

  This operation is idempotent - releasing a non-existent session is a no-op.
  When a session is released, all of its associated runs are also released.

  ## Parameters

  - `limiter` - The limiter server
  - `session_id` - The session identifier

  ## Returns

  - `:ok` - Always succeeds

  """
  @spec release_session_slot(GenServer.server(), String.t()) :: :ok
  def release_session_slot(limiter, session_id) do
    GenServer.call(limiter, {:release_session, session_id})
  end

  @doc """
  Attempts to acquire a run slot.

  Returns `:ok` if successful, or an error if the limit would be exceeded.

  This operation is idempotent - acquiring the same run_id multiple times
  only counts as one slot.

  ## Parameters

  - `limiter` - The limiter server
  - `session_id` - The parent session identifier
  - `run_id` - The run identifier

  ## Returns

  - `:ok` - Run slot acquired
  - `{:error, %Error{code: :max_runs_exceeded}}` - Limit exceeded

  """
  @spec acquire_run_slot(GenServer.server(), String.t(), String.t()) :: :ok | {:error, Error.t()}
  def acquire_run_slot(limiter, session_id, run_id) do
    GenServer.call(limiter, {:acquire_run, session_id, run_id})
  end

  @doc """
  Releases a run slot.

  This operation is idempotent - releasing a non-existent run is a no-op.

  ## Parameters

  - `limiter` - The limiter server
  - `run_id` - The run identifier

  ## Returns

  - `:ok` - Always succeeds

  """
  @spec release_run_slot(GenServer.server(), String.t()) :: :ok
  def release_run_slot(limiter, run_id) do
    GenServer.call(limiter, {:release_run, run_id})
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl GenServer
  def init(opts) do
    max_sessions = Keyword.get(opts, :max_parallel_sessions, Config.get(:max_parallel_sessions))
    max_runs = Keyword.get(opts, :max_parallel_runs, Config.get(:max_parallel_runs))

    state = %{
      max_parallel_sessions: max_sessions,
      max_parallel_runs: max_runs,
      # Map of session_id => true
      active_sessions: %{},
      # Map of run_id => session_id
      active_runs: %{},
      # Map of session_id => MapSet of run_ids
      session_runs: %{}
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_limits, _from, state) do
    limits = %{
      max_parallel_sessions: state.max_parallel_sessions,
      max_parallel_runs: state.max_parallel_runs
    }

    {:reply, limits, state}
  end

  def handle_call(:get_status, _from, state) do
    active_sessions = map_size(state.active_sessions)
    active_runs = map_size(state.active_runs)

    available_sessions = calculate_available(state.max_parallel_sessions, active_sessions)
    available_runs = calculate_available(state.max_parallel_runs, active_runs)

    status = %{
      active_sessions: active_sessions,
      active_runs: active_runs,
      max_parallel_sessions: state.max_parallel_sessions,
      max_parallel_runs: state.max_parallel_runs,
      available_session_slots: available_sessions,
      available_run_slots: available_runs
    }

    {:reply, status, state}
  end

  def handle_call({:acquire_session, session_id}, _from, state) do
    # Check if already acquired (idempotency)
    if Map.has_key?(state.active_sessions, session_id) do
      {:reply, :ok, state}
    else
      # Check if limit would be exceeded
      active_count = map_size(state.active_sessions)

      if limit_exceeded?(state.max_parallel_sessions, active_count) do
        error =
          Error.new(
            :max_sessions_exceeded,
            "Maximum parallel sessions limit (#{state.max_parallel_sessions}) exceeded. " <>
              "Currently active: #{active_count}"
          )

        {:reply, {:error, error}, state}
      else
        new_state = %{
          state
          | active_sessions: Map.put(state.active_sessions, session_id, true),
            session_runs: Map.put(state.session_runs, session_id, MapSet.new())
        }

        {:reply, :ok, new_state}
      end
    end
  end

  def handle_call({:release_session, session_id}, _from, state) do
    # Get all runs for this session and release them
    run_ids = Map.get(state.session_runs, session_id, MapSet.new())

    new_active_runs =
      Enum.reduce(run_ids, state.active_runs, fn run_id, acc ->
        Map.delete(acc, run_id)
      end)

    new_state = %{
      state
      | active_sessions: Map.delete(state.active_sessions, session_id),
        active_runs: new_active_runs,
        session_runs: Map.delete(state.session_runs, session_id)
    }

    {:reply, :ok, new_state}
  end

  def handle_call({:acquire_run, session_id, run_id}, _from, state) do
    # Check if already acquired (idempotency)
    if Map.has_key?(state.active_runs, run_id) do
      {:reply, :ok, state}
    else
      # Check if limit would be exceeded
      active_count = map_size(state.active_runs)

      if limit_exceeded?(state.max_parallel_runs, active_count) do
        error =
          Error.new(
            :max_runs_exceeded,
            "Maximum parallel runs limit (#{state.max_parallel_runs}) exceeded. " <>
              "Currently active: #{active_count}"
          )

        {:reply, {:error, error}, state}
      else
        # Track the run
        new_active_runs = Map.put(state.active_runs, run_id, session_id)

        # Associate run with session
        session_run_set = Map.get(state.session_runs, session_id, MapSet.new())

        new_session_runs =
          Map.put(state.session_runs, session_id, MapSet.put(session_run_set, run_id))

        new_state = %{
          state
          | active_runs: new_active_runs,
            session_runs: new_session_runs
        }

        {:reply, :ok, new_state}
      end
    end
  end

  def handle_call({:release_run, run_id}, _from, state) do
    case Map.get(state.active_runs, run_id) do
      nil ->
        # Run doesn't exist, no-op (idempotent)
        {:reply, :ok, state}

      session_id ->
        # Remove from active runs
        new_active_runs = Map.delete(state.active_runs, run_id)

        # Remove from session association
        session_run_set = Map.get(state.session_runs, session_id, MapSet.new())

        new_session_runs =
          Map.put(state.session_runs, session_id, MapSet.delete(session_run_set, run_id))

        new_state = %{
          state
          | active_runs: new_active_runs,
            session_runs: new_session_runs
        }

        {:reply, :ok, new_state}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp limit_exceeded?(:infinity, _current), do: false
  defp limit_exceeded?(max, current), do: current >= max

  defp calculate_available(:infinity, _current), do: :infinity
  defp calculate_available(max, current), do: max(0, max - current)
end
