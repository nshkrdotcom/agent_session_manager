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
  alias AgentSessionManager.Telemetry

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
  def start_session(store, adapter, attrs) do
    provider_name = ProviderAdapter.name(adapter)

    # Merge provider metadata into user-provided metadata
    provider_metadata = %{provider: provider_name}

    user_metadata = Map.get(attrs, :metadata, %{})
    merged_metadata = Map.merge(user_metadata, provider_metadata)
    attrs_with_provider = Map.put(attrs, :metadata, merged_metadata)

    with {:ok, session} <- Session.new(attrs_with_provider),
         :ok <- SessionStore.save_session(store, session),
         :ok <- emit_event(store, :session_created, session, %{provider: provider_name}) do
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

  ## Options

  - `:event_callback` - A function `(event_data -> any())` that receives each
    adapter event in real time, in addition to the internal persistence callback.

  ## Returns

  - `{:ok, result}` - Execution completed successfully
  - `{:error, Error.t()}` - Execution failed

  """
  @spec execute_run(store(), adapter(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def execute_run(store, adapter, run_id, opts \\ []) do
    with {:ok, run} <- SessionStore.get_run(store, run_id),
         {:ok, session} <- SessionStore.get_session(store, run.session_id),
         {:ok, running_run} <- Run.update_status(run, :running),
         :ok <- SessionStore.save_run(store, running_run) do
      execute_with_adapter(store, adapter, running_run, session, opts)
    end
  end

  @doc """
  Runs a one-shot session: creates a session, activates it, starts a run,
  executes it, and completes (or fails) the session — all in a single call.

  This is a convenience function that collapses the full session lifecycle
  into one function call, ideal for simple request/response workflows.

  ## Parameters

  - `store` - The session store instance
  - `adapter` - The provider adapter instance
  - `input` - Input data for the run (e.g. `%{messages: [...]}`)
  - `opts` - Options:
    - `:agent_id` - Agent identifier (defaults to provider name)
    - `:metadata` - Session metadata map
    - `:context` - Session context (system prompts, etc.)
    - `:tags` - Session tags
    - `:event_callback` - `(event_data -> any())` for real-time events
    - `:required_capabilities` - Required capability types
    - `:optional_capabilities` - Optional capability types

  ## Returns

  - `{:ok, result}` - A map with `:output`, `:token_usage`, `:events`,
    `:session_id`, and `:run_id`
  - `{:error, Error.t()}` - If any step fails

  ## Examples

      {:ok, result} = SessionManager.run_once(store, adapter, %{
        messages: [%{role: "user", content: "Hello!"}]
      }, event_callback: fn e -> IO.inspect(e.type) end)

      IO.puts(result.output.content)

  """
  @spec run_once(store(), adapter(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def run_once(store, adapter, input, opts \\ []) do
    agent_id = Keyword.get(opts, :agent_id, ProviderAdapter.name(adapter))

    session_attrs =
      %{agent_id: agent_id}
      |> maybe_put(:metadata, Keyword.get(opts, :metadata))
      |> maybe_put(:context, Keyword.get(opts, :context))
      |> maybe_put(:tags, Keyword.get(opts, :tags))

    cap_opts =
      []
      |> maybe_put_keyword(:required_capabilities, Keyword.get(opts, :required_capabilities))
      |> maybe_put_keyword(:optional_capabilities, Keyword.get(opts, :optional_capabilities))

    exec_opts =
      []
      |> maybe_put_keyword(:event_callback, Keyword.get(opts, :event_callback))

    with {:ok, session} <- start_session(store, adapter, session_attrs),
         {:ok, _active} <- activate_session(store, session.id) do
      run_once_execute(store, adapter, session, input, cap_opts, exec_opts)
    end
  end

  defp run_once_execute(store, adapter, session, input, cap_opts, exec_opts) do
    case start_run(store, adapter, session.id, input, cap_opts) do
      {:ok, run} ->
        case execute_run(store, adapter, run.id, exec_opts) do
          {:ok, result} ->
            {:ok, _} = complete_session(store, session.id)

            {:ok,
             %{
               output: result.output,
               token_usage: result.token_usage,
               events: result.events,
               session_id: session.id,
               run_id: run.id
             }}

          {:error, %Error{} = error} ->
            fail_session(store, session.id, error)
            {:error, error}
        end

      {:error, %Error{} = error} ->
        fail_session(store, session.id, error)
        {:error, error}
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

  defp execute_with_adapter(store, adapter, run, session, opts) do
    provider_name = ProviderAdapter.name(adapter)
    user_callback = Keyword.get(opts, :event_callback)

    event_callback = fn event_data ->
      handle_adapter_event(store, run, session, event_data)
      if user_callback, do: user_callback.(event_data)
    end

    case ProviderAdapter.execute(adapter, run, session, event_callback: event_callback) do
      {:ok, result} ->
        # Extract provider metadata from stored events
        provider_metadata = extract_provider_metadata_from_events(store, run)

        finalize_successful_run(store, run, session, result, provider_name, provider_metadata)

      {:error, error} ->
        finalize_failed_run(store, run, error)
    end
  end

  defp extract_provider_metadata_from_events(store, run) do
    {:ok, events} = SessionStore.get_events(store, run.session_id, run_id: run.id)

    # Find the run_started event and extract provider metadata
    case Enum.find(events, &(&1.type == :run_started)) do
      nil ->
        %{}

      event ->
        data = event.data

        %{
          provider_session_id:
            data[:provider_session_id] || data[:session_id] || data[:thread_id],
          model: data[:model],
          tools: data[:tools]
        }
    end
  end

  defp finalize_successful_run(store, run, session, result, provider_name, provider_metadata) do
    # Build run metadata with provider info
    run_provider_metadata =
      %{provider: provider_name}
      |> maybe_put(:provider_session_id, provider_metadata[:provider_session_id])
      |> maybe_put(:model, provider_metadata[:model])

    with {:ok, updated_run} <- Run.set_output(run, result.output),
         {:ok, run_with_usage} <- Run.update_token_usage(updated_run, result.token_usage),
         final_run = update_run_metadata(run_with_usage, run_provider_metadata),
         :ok <- SessionStore.save_run(store, final_run),
         :ok <- update_session_provider_metadata(store, session, provider_metadata) do
      {:ok, result}
    end
  end

  defp update_run_metadata(run, new_metadata) do
    merged_metadata = Map.merge(run.metadata, new_metadata)
    %{run | metadata: merged_metadata}
  end

  defp update_session_provider_metadata(store, session, provider_metadata) do
    # Only update if we have provider metadata to add
    metadata_to_add =
      %{}
      |> maybe_put(:provider_session_id, provider_metadata[:provider_session_id])
      |> maybe_put(:model, provider_metadata[:model])

    if map_size(metadata_to_add) > 0 do
      merged_metadata = Map.merge(session.metadata, metadata_to_add)
      updated_session = %{session | metadata: merged_metadata, updated_at: DateTime.utc_now()}
      SessionStore.save_session(store, updated_session)
    else
      :ok
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_keyword(keyword, _key, nil), do: keyword
  defp maybe_put_keyword(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp finalize_failed_run(store, run, error) do
    error_map = %{code: error.code, message: error.message}

    with {:ok, failed_run} <- Run.set_error(run, error_map),
         :ok <- SessionStore.save_run(store, failed_run),
         :ok <- emit_run_event(store, :run_failed, failed_run, %{error_code: error.code}) do
      {:error, error}
    end
  end

  defp handle_adapter_event(store, run, session, event_data) do
    # Normalize and store adapter events
    {:ok, event} =
      Event.new(%{
        type: event_data.type,
        session_id: run.session_id,
        run_id: run.id,
        data: Map.get(event_data, :data, %{})
      })

    SessionStore.append_event(store, event)

    # Emit telemetry event for observability
    Telemetry.emit_adapter_event(run, session, event_data)
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
