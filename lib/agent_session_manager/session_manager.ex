defmodule AgentSessionManager.SessionManager do
  @moduledoc """
  Orchestrates session lifecycle, run execution, and event handling.

  The SessionManager is the central coordinator for managing AI agent sessions.
  It handles:

  - Session creation, activation, and completion
  - Run creation and execution via provider adapters
  - Event emission and persistence
  - Capability requirement enforcement

  ## Architecture

  SessionManager sits between the application and the ports/adapters layer:

      Application
          |
      SessionManager  <-- Orchestration layer
          |
      +---+---+
      |       |
    Store   Adapter   <-- Ports (interfaces)
      |       |
    Impl    Impl      <-- Adapters (implementations)

  ## Usage

      # Start a session
      {:ok, store} = InMemorySessionStore.start_link()
      {:ok, adapter} = AnthropicAdapter.start_link(api_key: "...")

      {:ok, session} = SessionManager.start_session(store, adapter, %{
        agent_id: "my-agent",
        context: %{system_prompt: "You are helpful"}
      })

      # Activate and run
      {:ok, _} = SessionManager.activate_session(store, session.id)
      {:ok, run} = SessionManager.start_run(store, adapter, session.id, %{prompt: "Hello"})
      {:ok, result} = SessionManager.execute_run(store, adapter, run.id)

      # Complete session
      {:ok, _} = SessionManager.complete_session(store, session.id)

  ## Event Flow

  The SessionManager emits normalized events through the session store:

  1. Session lifecycle: `:session_created`, `:session_started`, `:session_completed`, etc.
  2. Run lifecycle: `:run_started`, `:run_completed`, `:run_failed`, etc.
  3. Provider events: Adapter events are normalized and stored

  """

  alias AgentSessionManager.Core.{CapabilityResolver, Error, Event, Run, Session}
  alias AgentSessionManager.Ports.{ProviderAdapter, SessionStore}

  @type store :: SessionStore.store()
  @type adapter :: ProviderAdapter.adapter()

  # ============================================================================
  # Session Lifecycle
  # ============================================================================

  @doc """
  Creates a new session with pending status.

  ## Parameters

  - `store` - The session store instance
  - `adapter` - The provider adapter instance
  - `attrs` - Session attributes:
    - `:agent_id` (required) - The agent identifier
    - `:metadata` - Optional metadata map
    - `:context` - Optional context map (system prompts, etc.)
    - `:tags` - Optional list of tags

  ## Returns

  - `{:ok, Session.t()}` - The created session
  - `{:error, Error.t()}` - If validation fails

  ## Examples

      {:ok, session} = SessionManager.start_session(store, adapter, %{
        agent_id: "my-agent",
        metadata: %{user_id: "user-123"}
      })

  """
  @spec start_session(store(), adapter(), map()) :: {:ok, Session.t()} | {:error, Error.t()}
  def start_session(store, _adapter, attrs) do
    with {:ok, session} <- Session.new(attrs),
         :ok <- SessionStore.save_session(store, session),
         :ok <- emit_event(store, :session_created, session) do
      {:ok, session}
    end
  end

  @doc """
  Retrieves a session by ID.

  ## Returns

  - `{:ok, Session.t()}` - The session
  - `{:error, Error.t()}` - If not found

  """
  @spec get_session(store(), String.t()) :: {:ok, Session.t()} | {:error, Error.t()}
  def get_session(store, session_id) do
    SessionStore.get_session(store, session_id)
  end

  @doc """
  Activates a pending session.

  Transitions the session from `:pending` to `:active` status.

  ## Returns

  - `{:ok, Session.t()}` - The activated session
  - `{:error, Error.t()}` - If session not found or update fails

  """
  @spec activate_session(store(), String.t()) :: {:ok, Session.t()} | {:error, Error.t()}
  def activate_session(store, session_id) do
    with {:ok, session} <- SessionStore.get_session(store, session_id),
         {:ok, activated} <- Session.update_status(session, :active),
         :ok <- SessionStore.save_session(store, activated),
         :ok <- emit_event(store, :session_started, activated) do
      {:ok, activated}
    end
  end

  @doc """
  Completes a session successfully.

  Transitions the session to `:completed` status.

  ## Returns

  - `{:ok, Session.t()}` - The completed session
  - `{:error, Error.t()}` - If session not found or update fails

  """
  @spec complete_session(store(), String.t()) :: {:ok, Session.t()} | {:error, Error.t()}
  def complete_session(store, session_id) do
    with {:ok, session} <- SessionStore.get_session(store, session_id),
         {:ok, completed} <- Session.update_status(session, :completed),
         :ok <- SessionStore.save_session(store, completed),
         :ok <- emit_event(store, :session_completed, completed) do
      {:ok, completed}
    end
  end

  @doc """
  Marks a session as failed.

  Transitions the session to `:failed` status and records the error.

  ## Parameters

  - `store` - The session store
  - `session_id` - The session ID
  - `error` - The error that caused the failure

  ## Returns

  - `{:ok, Session.t()}` - The failed session
  - `{:error, Error.t()}` - If session not found or update fails

  """
  @spec fail_session(store(), String.t(), Error.t()) :: {:ok, Session.t()} | {:error, Error.t()}
  def fail_session(store, session_id, %Error{} = error) do
    with {:ok, session} <- SessionStore.get_session(store, session_id),
         {:ok, failed} <- Session.update_status(session, :failed),
         :ok <- SessionStore.save_session(store, failed),
         :ok <-
           emit_event(store, :session_failed, failed, %{
             error_code: error.code,
             error_message: error.message
           }) do
      {:ok, failed}
    end
  end

  # ============================================================================
  # Run Lifecycle
  # ============================================================================

  @doc """
  Creates a new run for a session.

  The run is created with `:pending` status. Use `execute_run/3` to execute it.

  ## Parameters

  - `store` - The session store
  - `adapter` - The provider adapter
  - `session_id` - The parent session ID
  - `input` - Input data for the run
  - `opts` - Optional settings:
    - `:required_capabilities` - List of capability types that must be present
    - `:optional_capabilities` - List of capability types that are nice to have

  ## Returns

  - `{:ok, Run.t()}` - The created run
  - `{:error, Error.t()}` - If session not found or capability check fails

  """
  @spec start_run(store(), adapter(), String.t(), map(), keyword()) ::
          {:ok, Run.t()} | {:error, Error.t()}
  def start_run(store, adapter, session_id, input, opts \\ []) do
    with {:ok, _session} <- SessionStore.get_session(store, session_id),
         :ok <- check_capabilities(adapter, opts),
         {:ok, run} <- Run.new(%{session_id: session_id, input: input}),
         :ok <- SessionStore.save_run(store, run) do
      {:ok, run}
    end
  end

  @doc """
  Executes a run via the provider adapter.

  This function:
  1. Updates the run status to `:running`
  2. Calls the adapter's `execute/4` function
  3. Handles events emitted by the adapter
  4. Updates the run with results or error

  ## Returns

  - `{:ok, result}` - Execution completed successfully
  - `{:error, Error.t()}` - Execution failed

  """
  @spec execute_run(store(), adapter(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def execute_run(store, adapter, run_id) do
    with {:ok, run} <- SessionStore.get_run(store, run_id),
         {:ok, session} <- SessionStore.get_session(store, run.session_id),
         {:ok, running_run} <- Run.update_status(run, :running),
         :ok <- SessionStore.save_run(store, running_run) do
      execute_with_adapter(store, adapter, running_run, session)
    end
  end

  @doc """
  Cancels an in-progress run.

  ## Returns

  - `{:ok, run_id}` - Run was cancelled
  - `{:error, Error.t()}` - Cancellation failed

  """
  @spec cancel_run(store(), adapter(), String.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def cancel_run(store, adapter, run_id) do
    with {:ok, run} <- SessionStore.get_run(store, run_id),
         {:ok, _} <- ProviderAdapter.cancel(adapter, run_id),
         {:ok, cancelled_run} <- Run.update_status(run, :cancelled),
         :ok <- SessionStore.save_run(store, cancelled_run),
         :ok <- emit_run_event(store, :run_cancelled, cancelled_run) do
      {:ok, run_id}
    end
  end

  # ============================================================================
  # Queries
  # ============================================================================

  @doc """
  Gets all events for a session.

  ## Options

  - `:run_id` - Filter by run ID
  - `:type` - Filter by event type
  - `:since` - Events after this timestamp

  """
  @spec get_session_events(store(), String.t(), keyword()) :: {:ok, [Event.t()]}
  def get_session_events(store, session_id, opts \\ []) do
    SessionStore.get_events(store, session_id, opts)
  end

  @doc """
  Gets all runs for a session.
  """
  @spec get_session_runs(store(), String.t()) :: {:ok, [Run.t()]}
  def get_session_runs(store, session_id) do
    SessionStore.list_runs(store, session_id)
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp execute_with_adapter(store, adapter, run, session) do
    event_callback = fn event_data ->
      handle_adapter_event(store, run, event_data)
    end

    case ProviderAdapter.execute(adapter, run, session, event_callback: event_callback) do
      {:ok, result} ->
        finalize_successful_run(store, run, result)

      {:error, error} ->
        finalize_failed_run(store, run, error)
    end
  end

  defp finalize_successful_run(store, run, result) do
    with {:ok, updated_run} <- Run.set_output(run, result.output),
         {:ok, final_run} <- Run.update_token_usage(updated_run, result.token_usage),
         :ok <- SessionStore.save_run(store, final_run) do
      {:ok, result}
    end
  end

  defp finalize_failed_run(store, run, error) do
    error_map = %{code: error.code, message: error.message}

    with {:ok, failed_run} <- Run.set_error(run, error_map),
         :ok <- SessionStore.save_run(store, failed_run),
         :ok <- emit_run_event(store, :run_failed, failed_run, %{error_code: error.code}) do
      {:error, error}
    end
  end

  defp handle_adapter_event(store, run, event_data) do
    # Normalize and store adapter events
    {:ok, event} =
      Event.new(%{
        type: event_data.type,
        session_id: run.session_id,
        run_id: run.id,
        data: Map.get(event_data, :data, %{})
      })

    SessionStore.append_event(store, event)
  end

  defp check_capabilities(adapter, opts) do
    required = Keyword.get(opts, :required_capabilities, [])
    optional = Keyword.get(opts, :optional_capabilities, [])

    if Enum.empty?(required) and Enum.empty?(optional) do
      :ok
    else
      with {:ok, capabilities} <- ProviderAdapter.capabilities(adapter),
           {:ok, resolver} <- CapabilityResolver.new(required: required, optional: optional),
           {:ok, _result} <- CapabilityResolver.negotiate(resolver, capabilities) do
        :ok
      end
    end
  end

  defp emit_event(store, type, session, data \\ %{}) do
    {:ok, event} =
      Event.new(%{
        type: type,
        session_id: session.id,
        data: data
      })

    SessionStore.append_event(store, event)
  end

  defp emit_run_event(store, type, run, data \\ %{}) do
    {:ok, event} =
      Event.new(%{
        type: type,
        session_id: run.session_id,
        run_id: run.id,
        data: data
      })

    SessionStore.append_event(store, event)
  end
end
