defmodule AgentSessionManager.Telemetry do
  @moduledoc """
  Telemetry event emission for observability.

  This module provides functions to emit telemetry events for run lifecycle
  and usage metrics. Events follow the `:telemetry` library conventions and
  can be consumed by any telemetry handler (e.g., for metrics, logging, tracing).

  ## Event Names

  All events are prefixed with `[:agent_session_manager, ...]`:

  ### Run Lifecycle
  - `[:agent_session_manager, :run, :start]` - Emitted when a run starts
  - `[:agent_session_manager, :run, :stop]` - Emitted when a run completes successfully
  - `[:agent_session_manager, :run, :exception]` - Emitted when a run fails with an error
  - `[:agent_session_manager, :usage, :report]` - Emitted with usage metrics

  ### Persistence (emitted by `EventPipeline`)
  - `[:agent_session_manager, :persistence, :event_persisted]` - Event was validated and persisted
  - `[:agent_session_manager, :persistence, :event_validation_warning]` - Event had shape warnings
  - `[:agent_session_manager, :persistence, :event_rejected]` - Event failed structural validation
  - `[:agent_session_manager, :persistence, :event_redacted]` - Secrets were redacted from an event

  ## Configuration

  Telemetry is enabled by default. Disable it via application config
  (global baseline) or at runtime per-process:

      # Global baseline (config.exs)
      config :agent_session_manager, telemetry_enabled: false

      # Per-process override (safe in concurrent tests)
      AgentSessionManager.Telemetry.set_enabled(false)

  ## Usage

      alias AgentSessionManager.Telemetry

      # Manual event emission
      Telemetry.emit_run_start(run, session)
      Telemetry.emit_run_end(run, session, result)
      Telemetry.emit_error(run, session, error)

      # Or use the span helper for automatic start/stop/exception
      Telemetry.span(run, session, fn ->
        # Do work
        {:ok, result}
      end)

  ## Attaching Handlers

      :telemetry.attach_many(
        "my-handler",
        [
          [:agent_session_manager, :run, :start],
          [:agent_session_manager, :run, :stop],
          [:agent_session_manager, :run, :exception]
        ],
        &MyHandler.handle_event/4,
        nil
      )

  """

  alias AgentSessionManager.Config
  alias AgentSessionManager.Core.{Run, Session}

  # ============================================================================
  # Configuration
  # ============================================================================

  @doc """
  Returns whether telemetry is enabled.

  Checks the process-local override first, then Application environment,
  then defaults to `true`. See `AgentSessionManager.Config` for details.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Config.get(:telemetry_enabled)
  end

  @doc """
  Enables or disables telemetry for the current process.

  The override is process-local and automatically cleaned up when the
  process exits. This is safe to call in concurrent tests.
  """
  @spec set_enabled(boolean()) :: :ok
  def set_enabled(enabled) when is_boolean(enabled) do
    Config.put(:telemetry_enabled, enabled)
  end

  # ============================================================================
  # Run Lifecycle Events
  # ============================================================================

  @doc """
  Emits a `[:agent_session_manager, :run, :start]` event.

  ## Measurements

  - `system_time` - System time in native units when the run started

  ## Metadata

  - `run_id` - The run identifier
  - `session_id` - The session identifier
  - `agent_id` - The agent identifier
  - `run` - The full Run struct
  - `session` - The full Session struct

  """
  @spec emit_run_start(Run.t(), Session.t()) :: :ok
  def emit_run_start(%Run{} = run, %Session{} = session) do
    if enabled?() do
      :telemetry.execute(
        [:agent_session_manager, :run, :start],
        %{
          system_time: System.system_time()
        },
        %{
          run_id: run.id,
          session_id: session.id,
          agent_id: session.agent_id,
          run: run,
          session: session
        }
      )
    end

    :ok
  end

  @doc """
  Emits a `[:agent_session_manager, :run, :stop]` event.

  ## Measurements

  - `duration` - Duration in native time units (nanoseconds)
  - `input_tokens` - Number of input tokens (if provided)
  - `output_tokens` - Number of output tokens (if provided)
  - `total_tokens` - Total tokens (if provided)

  ## Metadata

  - `run_id` - The run identifier
  - `session_id` - The session identifier
  - `agent_id` - The agent identifier
  - `status` - The final run status
  - `run` - The full Run struct
  - `session` - The full Session struct

  """
  @spec emit_run_end(Run.t(), Session.t(), map()) :: :ok
  def emit_run_end(%Run{} = run, %Session{} = session, result) do
    if enabled?() do
      token_usage = Map.get(result, :token_usage, %{})

      measurements =
        %{
          duration: calculate_duration(run),
          system_time: System.system_time()
        }
        |> maybe_add_token_measurement(:input_tokens, token_usage)
        |> maybe_add_token_measurement(:output_tokens, token_usage)
        |> maybe_add_token_measurement(:total_tokens, token_usage)
        |> maybe_add_cost_measurement(result)

      :telemetry.execute(
        [:agent_session_manager, :run, :stop],
        measurements,
        %{
          run_id: run.id,
          session_id: session.id,
          agent_id: session.agent_id,
          status: run.status,
          run: run,
          session: session
        }
      )
    end

    :ok
  end

  @doc """
  Emits a `[:agent_session_manager, :run, :exception]` event.

  ## Measurements

  - `duration` - Duration in native time units (nanoseconds)
  - `system_time` - System time when the error occurred

  ## Metadata

  - `run_id` - The run identifier
  - `session_id` - The session identifier
  - `agent_id` - The agent identifier
  - `error_code` - The error code
  - `error_message` - The error message
  - `run` - The full Run struct
  - `session` - The full Session struct

  """
  @spec emit_error(Run.t(), Session.t(), map()) :: :ok
  def emit_error(%Run{} = run, %Session{} = session, error) do
    if enabled?() do
      :telemetry.execute(
        [:agent_session_manager, :run, :exception],
        %{
          duration: calculate_duration(run),
          system_time: System.system_time()
        },
        %{
          run_id: run.id,
          session_id: session.id,
          agent_id: session.agent_id,
          error_code: Map.get(error, :code),
          error_message: Map.get(error, :message),
          run: run,
          session: session,
          error: error
        }
      )
    end

    :ok
  end

  # ============================================================================
  # Usage Metrics Events
  # ============================================================================

  @doc """
  Emits a `[:agent_session_manager, :usage, :report]` event.

  ## Measurements

  All keys from the metrics map are included as measurements.
  Common keys include:
  - `input_tokens`
  - `output_tokens`
  - `total_tokens`
  - `cost_usd`

  ## Metadata

  - `session_id` - The session identifier
  - `agent_id` - The agent identifier
  - `session` - The full Session struct

  """
  @spec emit_usage_metrics(Session.t(), map()) :: :ok
  def emit_usage_metrics(%Session{} = session, metrics) when is_map(metrics) do
    if enabled?() do
      :telemetry.execute(
        [:agent_session_manager, :usage, :report],
        metrics,
        %{
          session_id: session.id,
          agent_id: session.agent_id,
          session: session
        }
      )
    end

    :ok
  end

  # ============================================================================
  # Span Helper
  # ============================================================================

  @doc """
  Wraps a function execution with telemetry events.

  Automatically emits:
  - `[:agent_session_manager, :run, :start]` before execution
  - `[:agent_session_manager, :run, :stop]` on `{:ok, result}`
  - `[:agent_session_manager, :run, :exception]` on `{:error, error}`

  ## Example

      Telemetry.span(run, session, fn ->
        # Perform the run
        {:ok, %{output: output, token_usage: usage}}
      end)

  """
  @spec span(Run.t(), Session.t(), (-> {:ok, map()} | {:error, map()})) ::
          {:ok, map()} | {:error, map()}
  def span(%Run{} = run, %Session{} = session, func) when is_function(func, 0) do
    emit_run_start(run, session)
    start_time = System.monotonic_time()

    result = func.()

    case result do
      {:ok, success_result} ->
        # Create a modified run with duration info for measurement
        duration = System.monotonic_time() - start_time
        run_with_timing = %{run | ended_at: DateTime.utc_now()}

        emit_run_end_with_duration(run_with_timing, session, success_result, duration)
        result

      {:error, error} ->
        emit_error(run, session, error)
        result
    end
  end

  # ============================================================================
  # Adapter Events
  # ============================================================================

  @doc """
  Emits an adapter event with the proper telemetry namespace.

  Events are emitted as `[:agent_session_manager, :adapter, event_type]`.

  ## Event Types

  Common adapter event types include:
  - `:run_started` - Execution begins
  - `:message_streamed` - Content chunk received
  - `:message_received` - Full message ready
  - `:tool_call_started` - Tool invocation begins
  - `:tool_call_completed` - Tool completes
  - `:token_usage_updated` - Usage stats update
  - `:run_completed` - Execution finishes
  - `:error_occurred` - Error during execution
  - `:run_failed` - Execution failed
  - `:run_cancelled` - Execution was cancelled

  ## Measurements

  Numeric values from the event data are included as measurements.

  ## Metadata

  - `run_id` - The run identifier
  - `session_id` - The session identifier
  - `agent_id` - The agent identifier
  - `provider` - The provider name (:claude, :codex, etc.)
  - `tool_name` - Tool name for tool events (if present)
  - `event_data` - The full event data map

  """
  @spec emit_adapter_event(Run.t(), Session.t(), map()) :: :ok
  def emit_adapter_event(%Run{} = run, %Session{} = session, event_data) do
    if enabled?() do
      event_type = Map.get(event_data, :type)
      data = Map.get(event_data, :data, %{})
      provider = Map.get(event_data, :provider)

      # Extract numeric values for measurements
      measurements =
        data
        |> Enum.filter(fn {_k, v} -> is_number(v) end)
        |> Enum.into(%{})
        |> Map.put(:system_time, System.system_time())

      # Build metadata
      metadata =
        %{
          run_id: run.id,
          session_id: session.id,
          agent_id: session.agent_id,
          provider: provider,
          event_data: data
        }
        |> maybe_add_tool_name(data)

      :telemetry.execute(
        [:agent_session_manager, :adapter, event_type],
        measurements,
        metadata
      )
    end

    :ok
  end

  defp maybe_add_tool_name(metadata, data) do
    case Map.get(data, :tool_name) do
      nil -> metadata
      tool_name -> Map.put(metadata, :tool_name, tool_name)
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp calculate_duration(%Run{started_at: started_at, ended_at: nil}) do
    if started_at do
      DateTime.diff(DateTime.utc_now(), started_at, :nanosecond)
    else
      0
    end
  end

  defp calculate_duration(%Run{started_at: started_at, ended_at: ended_at})
       when not is_nil(started_at) and not is_nil(ended_at) do
    DateTime.diff(ended_at, started_at, :nanosecond)
  end

  defp calculate_duration(_), do: 0

  defp maybe_add_token_measurement(measurements, key, token_usage) do
    case Map.get(token_usage, key) do
      nil -> measurements
      value when is_number(value) -> Map.put(measurements, key, value)
      _ -> measurements
    end
  end

  defp maybe_add_cost_measurement(measurements, result) do
    case Map.get(result, :cost_usd) do
      cost when is_number(cost) -> Map.put(measurements, :cost_usd, cost)
      _ -> measurements
    end
  end

  defp emit_run_end_with_duration(%Run{} = run, %Session{} = session, result, duration) do
    if enabled?() do
      token_usage = Map.get(result, :token_usage, %{})

      measurements =
        %{
          duration: duration,
          system_time: System.system_time()
        }
        |> maybe_add_token_measurement(:input_tokens, token_usage)
        |> maybe_add_token_measurement(:output_tokens, token_usage)
        |> maybe_add_token_measurement(:total_tokens, token_usage)
        |> maybe_add_cost_measurement(result)

      :telemetry.execute(
        [:agent_session_manager, :run, :stop],
        measurements,
        %{
          run_id: run.id,
          session_id: session.id,
          agent_id: session.agent_id,
          status: run.status,
          run: run,
          session: session
        }
      )
    end

    :ok
  end
end
