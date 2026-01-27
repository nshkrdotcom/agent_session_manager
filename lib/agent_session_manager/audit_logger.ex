defmodule AgentSessionManager.AuditLogger do
  @moduledoc """
  Audit log persistence for observability and compliance.

  This module provides functions to persist audit events to the SessionStore
  in append-only order. Events are immutable once stored and provide a
  complete audit trail of all run lifecycle events.

  ## Event Types

  - `:run_started` - Logged when a run begins
  - `:run_completed` - Logged when a run completes successfully
  - `:run_failed` - Logged when a run fails
  - `:error_occurred` - Logged when an error occurs during execution
  - `:token_usage_updated` - Logged when usage metrics are reported

  ## Configuration

  Audit logging is enabled by default. Disable it via application config
  (global baseline) or at runtime per-process:

      # Global baseline (config.exs)
      config :agent_session_manager, audit_logging_enabled: false

      # Per-process override (safe in concurrent tests)
      AgentSessionManager.AuditLogger.set_enabled(false)

  ## Usage

      alias AgentSessionManager.AuditLogger

      # Log lifecycle events
      AuditLogger.log_run_started(store, run, session)
      AuditLogger.log_run_completed(store, run, session, result)
      AuditLogger.log_run_failed(store, run, session, error)

      # Query audit log
      {:ok, events} = AuditLogger.get_audit_log(store, session_id)

  ## Telemetry Integration

  The AuditLogger can automatically log events from telemetry:

      AuditLogger.attach_telemetry_handlers(store)

  This will create audit log entries for all telemetry events emitted
  by the Telemetry module.

  """

  alias AgentSessionManager.Config
  alias AgentSessionManager.Core.{Event, Run, Session}
  alias AgentSessionManager.Ports.SessionStore

  @telemetry_handler_id "agent_session_manager_audit_logger"

  # ============================================================================
  # Configuration
  # ============================================================================

  @doc """
  Returns whether audit logging is enabled.

  Checks the process-local override first, then Application environment,
  then defaults to `true`. See `AgentSessionManager.Config` for details.
  """
  @spec enabled?() :: boolean()
  def enabled? do
    Config.get(:audit_logging_enabled)
  end

  @doc """
  Enables or disables audit logging for the current process.

  The override is process-local and automatically cleaned up when the
  process exits. This is safe to call in concurrent tests.
  """
  @spec set_enabled(boolean()) :: :ok
  def set_enabled(enabled) when is_boolean(enabled) do
    Config.put(:audit_logging_enabled, enabled)
  end

  # ============================================================================
  # Audit Event Logging
  # ============================================================================

  @doc """
  Logs a run_started audit event.

  ## Parameters

  - `store` - The session store instance
  - `run` - The run that started
  - `session` - The session containing the run

  """
  @spec log_run_started(SessionStore.store(), Run.t(), Session.t()) :: :ok
  def log_run_started(store, %Run{} = run, %Session{} = session) do
    if enabled?() do
      {:ok, event} =
        Event.new(%{
          type: :run_started,
          session_id: session.id,
          run_id: run.id,
          data: %{
            agent_id: session.agent_id,
            run_status: run.status
          }
        })

      SessionStore.append_event(store, event)
    end

    :ok
  end

  @doc """
  Logs a run_completed audit event.

  ## Parameters

  - `store` - The session store instance
  - `run` - The run that completed
  - `session` - The session containing the run
  - `result` - The result of the run including token_usage

  """
  @spec log_run_completed(SessionStore.store(), Run.t(), Session.t(), map()) :: :ok
  def log_run_completed(store, %Run{} = run, %Session{} = session, result) do
    if enabled?() do
      token_usage = Map.get(result, :token_usage, %{})

      {:ok, event} =
        Event.new(%{
          type: :run_completed,
          session_id: session.id,
          run_id: run.id,
          data: %{
            agent_id: session.agent_id,
            token_usage: token_usage
          }
        })

      SessionStore.append_event(store, event)
    end

    :ok
  end

  @doc """
  Logs a run_failed audit event.

  ## Parameters

  - `store` - The session store instance
  - `run` - The run that failed
  - `session` - The session containing the run
  - `error` - The error that caused the failure

  """
  @spec log_run_failed(SessionStore.store(), Run.t(), Session.t(), map()) :: :ok
  def log_run_failed(store, %Run{} = run, %Session{} = session, error) do
    if enabled?() do
      {:ok, event} =
        Event.new(%{
          type: :run_failed,
          session_id: session.id,
          run_id: run.id,
          data: %{
            agent_id: session.agent_id,
            error_code: Map.get(error, :code),
            error_message: Map.get(error, :message)
          }
        })

      SessionStore.append_event(store, event)
    end

    :ok
  end

  @doc """
  Logs an error_occurred audit event.

  ## Parameters

  - `store` - The session store instance
  - `run` - The run where the error occurred
  - `session` - The session containing the run
  - `error` - The error details

  """
  @spec log_error(SessionStore.store(), Run.t(), Session.t(), map()) :: :ok
  def log_error(store, %Run{} = run, %Session{} = session, error) do
    if enabled?() do
      {:ok, event} =
        Event.new(%{
          type: :error_occurred,
          session_id: session.id,
          run_id: run.id,
          data: %{
            agent_id: session.agent_id,
            error_code: Map.get(error, :code),
            error_message: Map.get(error, :message)
          }
        })

      SessionStore.append_event(store, event)
    end

    :ok
  end

  @doc """
  Logs a token_usage_updated audit event.

  ## Parameters

  - `store` - The session store instance
  - `session` - The session for the usage metrics
  - `metrics` - The usage metrics map
  - `opts` - Optional keyword list:
    - `:run_id` - The run ID to associate with the metrics

  """
  @spec log_usage_metrics(SessionStore.store(), Session.t(), map(), keyword()) :: :ok
  def log_usage_metrics(store, %Session{} = session, metrics, opts \\ []) do
    if enabled?() do
      run_id = Keyword.get(opts, :run_id)

      {:ok, event} =
        Event.new(%{
          type: :token_usage_updated,
          session_id: session.id,
          run_id: run_id,
          data: metrics
        })

      SessionStore.append_event(store, event)
    end

    :ok
  end

  # ============================================================================
  # Audit Log Queries
  # ============================================================================

  @doc """
  Retrieves audit events for a session.

  ## Parameters

  - `store` - The session store instance
  - `session_id` - The session ID to query
  - `opts` - Optional filters:
    - `:run_id` - Filter by run ID
    - `:type` - Filter by event type
    - `:since` - Events after this timestamp

  ## Returns

  - `{:ok, [Event.t()]}` - List of events in append order

  """
  @spec get_audit_log(SessionStore.store(), String.t(), keyword()) :: {:ok, [Event.t()]}
  def get_audit_log(store, session_id, opts \\ []) do
    SessionStore.get_events(store, session_id, opts)
  end

  # ============================================================================
  # Telemetry Integration
  # ============================================================================

  @doc """
  Attaches telemetry handlers to automatically log audit events.

  When attached, telemetry events emitted by the Telemetry module
  will automatically create corresponding audit log entries.

  ## Parameters

  - `store` - The session store instance to use for logging

  """
  @spec attach_telemetry_handlers(SessionStore.store()) :: :ok
  def attach_telemetry_handlers(store) do
    events = [
      [:agent_session_manager, :run, :start],
      [:agent_session_manager, :run, :stop],
      [:agent_session_manager, :run, :exception],
      [:agent_session_manager, :usage, :report]
    ]

    # Store the store reference in a process-accessible way
    :persistent_term.put({__MODULE__, :store}, store)

    # Use fully qualified MFA to avoid "local function" telemetry warning
    :telemetry.attach_many(
      @telemetry_handler_id,
      events,
      &__MODULE__.handle_telemetry_event/4,
      nil
    )

    :ok
  end

  @doc """
  Detaches the telemetry handlers.
  """
  @spec detach_telemetry_handlers() :: :ok
  def detach_telemetry_handlers do
    :telemetry.detach(@telemetry_handler_id)
    :persistent_term.erase({__MODULE__, :store})
    :ok
  rescue
    _ -> :ok
  end

  # ============================================================================
  # Private: Telemetry Handler
  # ============================================================================

  # Public to avoid telemetry "local function" warning - called by telemetry library
  @doc false
  def handle_telemetry_event(
        [:agent_session_manager, :run, :start],
        _measurements,
        metadata,
        _config
      ) do
    store = get_store()
    run = Map.get(metadata, :run)
    session = Map.get(metadata, :session)

    if store && run && session do
      log_run_started(store, run, session)
    end
  end

  def handle_telemetry_event(
        [:agent_session_manager, :run, :stop],
        measurements,
        metadata,
        _config
      ) do
    store = get_store()
    run = Map.get(metadata, :run)
    session = Map.get(metadata, :session)

    if store && run && session do
      result = %{
        token_usage:
          measurements
          |> Map.take([:input_tokens, :output_tokens, :total_tokens])
      }

      log_run_completed(store, run, session, result)
    end
  end

  def handle_telemetry_event(
        [:agent_session_manager, :run, :exception],
        _measurements,
        metadata,
        _config
      ) do
    store = get_store()
    run = Map.get(metadata, :run)
    session = Map.get(metadata, :session)

    if store && run && session do
      error = %{
        code: Map.get(metadata, :error_code),
        message: Map.get(metadata, :error_message)
      }

      log_run_failed(store, run, session, error)
    end
  end

  def handle_telemetry_event(
        [:agent_session_manager, :usage, :report],
        measurements,
        metadata,
        _config
      ) do
    store = get_store()
    session = Map.get(metadata, :session)

    if store && session do
      log_usage_metrics(store, session, measurements)
    end
  end

  def handle_telemetry_event(_event, _measurements, _metadata, _config) do
    :ok
  end

  defp get_store do
    :persistent_term.get({__MODULE__, :store}, nil)
  rescue
    _ -> nil
  end
end
