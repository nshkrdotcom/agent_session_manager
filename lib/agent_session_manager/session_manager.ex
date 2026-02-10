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

  alias AgentSessionManager.Core.{
    CapabilityResolver,
    Error,
    Event,
    Run,
    Session,
    TranscriptBuilder
  }

  alias AgentSessionManager.Persistence.EventPipeline
  alias AgentSessionManager.Policy.{AdapterCompiler, Policy, Preflight, Runtime}
  alias AgentSessionManager.Ports.{ArtifactStore, ProviderAdapter, SessionStore}
  alias AgentSessionManager.Telemetry
  alias AgentSessionManager.Workspace.{Diff, Snapshot, Workspace}

  @type store :: SessionStore.store()
  @type run_once_store :: store()
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
         :ok <- safe_save_session(store, session, :start_session),
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
    with {:ok, session} <- safe_get_session(store, session_id, :activate_session),
         {:ok, activated} <- Session.update_status(session, :active),
         :ok <- safe_save_session(store, activated, :activate_session),
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
    with {:ok, session} <- safe_get_session(store, session_id, :complete_session),
         {:ok, completed} <- Session.update_status(session, :completed),
         :ok <- safe_save_session(store, completed, :complete_session),
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
    with {:ok, session} <- safe_get_session(store, session_id, :fail_session),
         {:ok, failed} <- Session.update_status(session, :failed),
         :ok <- safe_save_session(store, failed, :fail_session),
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

  The run is created with `:pending` status. Use `execute_run/4` to execute it.

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
    with {:ok, _session} <- safe_get_session(store, session_id, :start_run),
         :ok <- check_capabilities(adapter, opts),
         {:ok, run} <- Run.new(%{session_id: session_id, input: input}),
         :ok <- safe_save_run(store, run, :start_run) do
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
  - `:continuation` - When `true`, reconstruct and inject a transcript into
    `session.context[:transcript]` before adapter execution.
  - `:continuation_opts` - Options forwarded to `TranscriptBuilder.from_store/3`
    (for example: `:limit`, `:after`, `:since`, `:max_messages`).
  - `:adapter_opts` - Additional adapter-specific options passed through to
    `ProviderAdapter.execute/4`.
  - `:policy` - Policy definition (`%AgentSessionManager.Policy.Policy{}` or attributes)
    for runtime budget/tool enforcement (single policy shorthand).
  - `:policies` - A list of policies to stack-merge into one effective policy.
    When both `:policy` and `:policies` are given, `:policies` takes precedence.
  - `:workspace` - Workspace snapshot/diff options:
    `enabled`, `path`, `strategy`, `capture_patch`, `max_patch_bytes`,
    and `rollback_on_failure` (git backend only in MVP).

  ## Returns

  - `{:ok, result}` - Execution completed successfully
  - `{:error, Error.t()}` - Execution failed

  """
  @spec execute_run(store(), adapter(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def execute_run(store, adapter, run_id, opts \\ []) do
    with {:ok, run} <- safe_get_run(store, run_id, :execute_run),
         {:ok, session} <- safe_get_session(store, run.session_id, :execute_run),
         {:ok, running_run} <- Run.update_status(run, :running),
         :ok <- safe_save_run(store, running_run, :execute_run) do
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
  - `:continuation` - Enable transcript reconstruction and continuity replay
  - `:continuation_opts` - Transcript builder options
  - `:adapter_opts` - Adapter-specific passthrough options
  - `:policy` - Policy definition for runtime budget/tool enforcement
  - `:workspace` - Workspace snapshot/diff options
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
  @spec run_once(run_once_store(), adapter(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def run_once(store, adapter, input, opts \\ []) do
    case resolve_run_once_store(store) do
      {:session, session_store} ->
        run_once_with_session_store(session_store, adapter, input, opts)

      {:error, _} = error ->
        error
    end
  end

  defp run_once_with_session_store(store, adapter, input, opts) do
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
      |> maybe_put_keyword(:continuation, Keyword.get(opts, :continuation))
      |> maybe_put_keyword(:continuation_opts, Keyword.get(opts, :continuation_opts))
      |> maybe_put_keyword(:adapter_opts, Keyword.get(opts, :adapter_opts))
      |> maybe_put_keyword(:policy, Keyword.get(opts, :policy))
      |> maybe_put_keyword(:policies, Keyword.get(opts, :policies))
      |> maybe_put_keyword(:workspace, Keyword.get(opts, :workspace))

    with {:ok, session} <- start_session(store, adapter, session_attrs),
         {:ok, _active} <- activate_session(store, session.id) do
      run_once_execute(store, adapter, session, input, cap_opts, exec_opts)
    end
  end

  defp resolve_run_once_store(store) when is_atom(store) do
    case Process.whereis(store) do
      pid when is_pid(pid) ->
        {:session, store}

      _ ->
        {:error,
         Error.new(
           :validation_error,
           "Store must be a SessionStore server: #{inspect(store)}"
         )}
    end
  end

  defp resolve_run_once_store(store) when is_pid(store), do: {:session, store}
  defp resolve_run_once_store({:via, _registry, _name} = store), do: {:session, store}
  defp resolve_run_once_store({:global, _name} = store), do: {:session, store}

  defp resolve_run_once_store(store) do
    {:error,
     Error.new(
       :validation_error,
       "Unsupported store reference for run_once/4: #{inspect(store)}"
     )}
  end

  defp run_once_execute(store, adapter, session, input, cap_opts, exec_opts) do
    case start_run(store, adapter, session.id, input, cap_opts) do
      {:ok, run} ->
        run_once_execute_started_run(store, adapter, session, run, exec_opts)

      {:error, %Error{} = error} ->
        _ = fail_session(store, session.id, error)
        {:error, error}
    end
  end

  defp run_once_execute_started_run(store, adapter, session, run, exec_opts) do
    case execute_run(store, adapter, run.id, exec_opts) do
      {:ok, result} ->
        finalize_run_once_execution(store, session.id, run.id, result)

      {:error, %Error{} = error} ->
        _ = fail_session(store, session.id, error)
        {:error, error}
    end
  end

  defp finalize_run_once_execution(store, session_id, run_id, result) do
    case complete_session(store, session_id) do
      {:ok, _} ->
        {:ok,
         %{
           output: result.output,
           token_usage: result.token_usage,
           events: result.events,
           session_id: session_id,
           run_id: run_id
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Cancels an in-progress run.

  ## Returns

  - `{:ok, run_id}` - Run was cancelled
  - `{:error, Error.t()}` - Cancellation failed

  Cancellation is best-effort. If the adapter process has already exited
  (`:noproc`/shutdown race), we still persist the run as `:cancelled` to
  honour caller intent and avoid leaving the run in a non-terminal state.

  """
  @spec cancel_run(store(), adapter(), String.t()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def cancel_run(store, adapter, run_id) do
    with {:ok, run} <- safe_get_run(store, run_id, :cancel_run),
         :ok <- request_run_cancel(adapter, run_id),
         {:ok, cancelled_run} <- Run.update_status(run, :cancelled),
         :ok <- safe_save_run(store, cancelled_run, :cancel_run),
         :ok <- emit_run_event(store, :run_cancelled, cancelled_run) do
      {:ok, run_id}
    end
  end

  @spec request_run_cancel(adapter(), String.t()) :: :ok | {:error, Error.t()}
  defp request_run_cancel(adapter, run_id) do
    case ProviderAdapter.cancel(adapter, run_id) do
      {:ok, _} ->
        :ok

      # Best-effort semantics: if the adapter is already gone, persist
      # cancellation intent rather than failing the control path.
      {:error, %Error{code: :provider_unavailable}} ->
        :ok

      {:error, %Error{} = error} ->
        {:error, error}
    end
  catch
    :exit, reason ->
      if adapter_unavailable_exit_reason?(reason) do
        :ok
      else
        {:error,
         Error.new(
           :provider_unavailable,
           "Adapter became unavailable while cancelling run #{run_id}: #{inspect(reason)}"
         )}
      end
  end

  defp adapter_unavailable_exit_reason?(:noproc), do: true
  defp adapter_unavailable_exit_reason?({:noproc, _}), do: true
  defp adapter_unavailable_exit_reason?({:shutdown, {:noproc, _}}), do: true
  defp adapter_unavailable_exit_reason?({:shutdown, _}), do: true
  defp adapter_unavailable_exit_reason?(_), do: false

  # ============================================================================
  # Queries
  # ============================================================================

  @doc """
  Gets all events for a session.

  ## Options

  - `:run_id` - Filter by run ID
  - `:type` - Filter by event type
  - `:since` - Events after this timestamp
  - `:after` - Events with sequence number greater than this cursor
  - `:before` - Events with sequence number less than this cursor
  - `:limit` - Maximum number of events to return

  """
  @spec get_session_events(store(), String.t(), keyword()) :: {:ok, [Event.t()]}
  def get_session_events(store, session_id, opts \\ []) do
    SessionStore.get_events(store, session_id, opts)
  end

  @doc """
  Streams session events by polling cursor-based reads from the store.

  The returned stream is open-ended and will keep polling for new events.

  ## Options

  - `:after` - Starting cursor (default: `0`)
  - `:limit` - Page size per poll (default: `100`)
  - `:poll_interval_ms` - Poll interval when no new events (default: `250`).
    Ignored when `:wait_timeout_ms` is set.
  - `:wait_timeout_ms` - When set to a positive integer, the stream uses
    store-backed long-poll semantics instead of sleep-based polling. The store's
    `get_events/3` is called with this option so stores that support it can
    block until matching events arrive or the timeout elapses, avoiding busy
    polling.
  - `:run_id` - Optional run filter
  - `:type` - Optional event type filter
  """
  @spec stream_session_events(store(), String.t(), keyword()) :: Enumerable.t()
  def stream_session_events(store, session_id, opts \\ []) do
    initial_cursor = Keyword.get(opts, :after, 0)
    page_limit = Keyword.get(opts, :limit, 100)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, 250)
    wait_timeout_ms = Keyword.get(opts, :wait_timeout_ms, 0)
    query_filters = Keyword.take(opts, [:run_id, :type, :since, :before])

    Stream.resource(
      fn -> initial_cursor end,
      fn cursor ->
        query_opts =
          query_filters
          |> Keyword.put(:after, cursor)
          |> Keyword.put(:limit, page_limit)

        {:ok, events} = SessionStore.get_events(store, session_id, query_opts)

        case events do
          [] ->
            stream_wait_for_events(
              store,
              session_id,
              query_opts,
              cursor,
              wait_timeout_ms,
              poll_interval_ms
            )

          _ ->
            next_cursor = advance_cursor(cursor, events)
            {events, next_cursor}
        end
      end,
      fn _cursor -> :ok end
    )
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
    callback_owner = self()

    with {:ok, effective_policy} <- resolve_effective_policy(opts),
         :ok <- maybe_preflight_check(effective_policy),
         {:ok, execution_session} <- maybe_attach_transcript(store, session, opts),
         {:ok, workspace_state} <- maybe_prepare_workspace(store, run, opts),
         :ok <- persist_input_messages(store, run),
         {:ok, policy_runtime} <-
           maybe_start_policy_runtime_from_effective(
             effective_policy,
             provider_name,
             run.id
           ) do
      event_callback =
        build_event_callback(
          store,
          run,
          execution_session,
          user_callback,
          adapter,
          policy_runtime,
          callback_owner
        )

      adapter_opts =
        opts
        |> Keyword.get(:adapter_opts, [])
        |> Keyword.put(:event_callback, event_callback)
        |> maybe_compile_policy_opts(effective_policy, provider_name)

      provider_result =
        ProviderAdapter.execute(adapter, run, execution_session, adapter_opts)

      callback_provider_metadata = collect_provider_metadata(run.id)

      case apply_policy_result(provider_result, policy_runtime) do
        {:ok, result} ->
          finalize_provider_success(
            store,
            run,
            session,
            provider_name,
            result,
            workspace_state,
            callback_provider_metadata
          )

        {:error, error} ->
          finalize_provider_failure(store, run, error, workspace_state)
      end
    else
      {:error, error} ->
        finalize_failed_run(store, run, error, %{})
    end
  end

  defp build_event_callback(
         store,
         run,
         execution_session,
         user_callback,
         adapter,
         policy_runtime,
         callback_owner
       ) do
    provider_name = ProviderAdapter.name(adapter)

    pipeline_context = %{
      session_id: run.session_id,
      run_id: run.id,
      provider: provider_name,
      correlation_id: Map.get(execution_session.metadata, :correlation_id)
    }

    fn event_data ->
      enriched_event_data =
        case EventPipeline.process(store, event_data, pipeline_context) do
          {:ok, event} ->
            event_data
            |> Map.put(:type, event.type)
            |> Map.put(:sequence_number, event.sequence_number)

          {:error, _} ->
            event_data
        end

      maybe_publish_provider_metadata(callback_owner, run.id, enriched_event_data)
      maybe_enforce_policy(store, run, adapter, policy_runtime, enriched_event_data)
      maybe_invoke_user_callback(user_callback, enriched_event_data)
      Telemetry.emit_adapter_event(run, execution_session, enriched_event_data)
    end
  end

  defp finalize_provider_success(
         store,
         run,
         session,
         provider_name,
         result,
         workspace_state,
         callback_provider_metadata
       ) do
    case maybe_finalize_workspace_success(store, run, result, workspace_state) do
      {:ok, result_with_workspace, workspace_metadata} ->
        provider_metadata =
          callback_provider_metadata
          |> Map.merge(extract_provider_metadata_from_result(result_with_workspace))

        finalize_successful_run(
          store,
          run,
          session,
          result_with_workspace,
          provider_name,
          provider_metadata,
          workspace_metadata
        )

      {:error, error} ->
        finalize_failed_run(store, run, error, %{})
    end
  end

  defp finalize_provider_failure(store, run, error, workspace_state) do
    case maybe_finalize_workspace_failure(store, run, workspace_state, error) do
      {:ok, workspace_metadata} ->
        finalize_failed_run(store, run, error, workspace_metadata)

      {:error, workspace_error} ->
        finalize_failed_run(store, run, workspace_error, %{})
    end
  end

  # Resolve the effective policy from :policies or :policy options.
  # :policies takes precedence when both are provided.
  defp resolve_effective_policy(opts) do
    policies = Keyword.get(opts, :policies)
    policy = Keyword.get(opts, :policy)

    cond do
      is_list(policies) and policies != [] ->
        resolve_policies_stack(policies)

      policy != nil ->
        case normalize_policy(policy) do
          {:ok, p} -> {:ok, p}
          error -> error
        end

      true ->
        {:ok, nil}
    end
  end

  defp resolve_policies_stack(policies) do
    normalized =
      Enum.reduce_while(policies, {:ok, []}, fn policy_input, {:ok, acc} ->
        case normalize_policy(policy_input) do
          {:ok, policy} -> {:cont, {:ok, acc ++ [policy]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case normalized do
      {:ok, policy_list} -> {:ok, Policy.stack_merge(policy_list)}
      error -> error
    end
  end

  defp maybe_preflight_check(nil), do: :ok

  defp maybe_preflight_check(%Policy{} = policy) do
    Preflight.check(policy)
  end

  defp maybe_start_policy_runtime_from_effective(nil, _provider_name, _run_id), do: {:ok, nil}

  defp maybe_start_policy_runtime_from_effective(%Policy{} = policy, provider_name, run_id) do
    Runtime.start_link(policy: policy, provider: provider_name, run_id: run_id)
  end

  defp maybe_compile_policy_opts(adapter_opts, nil, _provider_name), do: adapter_opts

  defp maybe_compile_policy_opts(adapter_opts, %Policy{} = policy, provider_name) do
    compiled = AdapterCompiler.compile(policy, provider_name)
    Keyword.merge(adapter_opts, compiled)
  end

  defp normalize_policy(%Policy{} = policy), do: {:ok, policy}
  defp normalize_policy(policy_input), do: Policy.new(policy_input)

  defp apply_policy_result(provider_result, nil), do: provider_result

  defp apply_policy_result(provider_result, policy_runtime) do
    policy_status = Runtime.status(policy_runtime)
    stop_policy_runtime(policy_runtime)

    cond do
      policy_status.violated? and policy_status.action == :cancel ->
        {:error, policy_violation_error(policy_status)}

      policy_status.violated? and policy_status.action == :warn ->
        case provider_result do
          {:ok, result} ->
            policy_metadata = %{
              action: :warn,
              violations: policy_status.violations,
              metadata: policy_status.metadata
            }

            {:ok, Map.put(result, :policy, policy_metadata)}

          other ->
            other
        end

      true ->
        provider_result
    end
  end

  defp stop_policy_runtime(policy_runtime) do
    if Process.alive?(policy_runtime) do
      GenServer.stop(policy_runtime, :normal)
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp policy_violation_error(policy_status) do
    Error.new(
      :policy_violation,
      "Policy violation triggered run cancellation",
      details: %{
        policy: policy_status.policy.name,
        violations: policy_status.violations
      }
    )
  end

  defp maybe_enforce_policy(_store, _run, _adapter, nil, _event_data), do: :ok

  defp maybe_enforce_policy(store, run, adapter, policy_runtime, event_data) do
    case Runtime.observe_event(policy_runtime, event_data) do
      {:ok, %{violations: violations, cancel?: cancel_now?}} ->
        Enum.each(violations, fn violation ->
          _ = emit_policy_violation_event(store, run, violation)
        end)

        if cancel_now? do
          _ = ProviderAdapter.cancel(adapter, run.id)
        end

        :ok
    end
  end

  defp emit_policy_violation_event(store, run, violation) do
    emit_run_event(store, :policy_violation, run, %{
      policy: violation.policy,
      kind: violation.kind,
      action: violation.action,
      details: violation.details
    })
  end

  defp maybe_invoke_user_callback(nil, _event_data), do: :ok

  defp maybe_invoke_user_callback(user_callback, event_data) when is_function(user_callback, 1) do
    user_callback.(event_data)
    :ok
  end

  defp maybe_publish_provider_metadata(owner_pid, run_id, event_data) when is_pid(owner_pid) do
    case extract_provider_metadata_from_event_data(event_data) do
      metadata when map_size(metadata) > 0 ->
        send(owner_pid, {:provider_metadata, run_id, metadata})
        :ok

      _ ->
        :ok
    end
  end

  defp collect_provider_metadata(run_id, acc \\ %{}) do
    receive do
      {:provider_metadata, ^run_id, metadata} when is_map(metadata) ->
        collect_provider_metadata(run_id, Map.merge(acc, metadata))
    after
      0 ->
        acc
    end
  end

  defp extract_provider_metadata_from_result(result) when is_map(result) do
    events =
      case Map.get(result, :events) do
        event_list when is_list(event_list) -> event_list
        _ -> []
      end

    case Enum.find(events, fn event -> event_type(event) == :run_started end) do
      nil -> %{}
      event -> extract_provider_metadata_from_event_data(event)
    end
  end

  defp extract_provider_metadata_from_event_data(event_data) do
    case event_type(event_data) do
      :run_started ->
        event_data
        |> event_data_map()
        |> normalize_provider_metadata()

      _ ->
        %{}
    end
  end

  defp event_type(%Event{type: type}) when is_atom(type), do: type
  defp event_type(%{type: type}) when is_atom(type), do: type
  defp event_type(%{type: "run_started"}), do: :run_started
  defp event_type(%{"type" => "run_started"}), do: :run_started
  defp event_type(_), do: nil

  defp event_data_map(%Event{data: data}) when is_map(data), do: data
  defp event_data_map(%{data: data}) when is_map(data), do: data
  defp event_data_map(%{"data" => data}) when is_map(data), do: data
  defp event_data_map(_), do: %{}

  defp normalize_provider_metadata(data) do
    %{
      provider_session_id:
        map_get(data, :provider_session_id) || map_get(data, :session_id) ||
          map_get(data, :thread_id),
      model: map_get(data, :model),
      tools: map_get(data, :tools)
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp maybe_attach_transcript(store, session, opts) do
    continuation_mode = resolve_continuation_mode(Keyword.get(opts, :continuation, false))

    case continuation_mode do
      :disabled ->
        {:ok, session}

      :native ->
        {:error,
         Error.new(
           :invalid_operation,
           "Native continuation is not available for this provider. " <>
             "Use continuation: :auto to fall back to transcript replay."
         )}

      mode when mode in [:auto, :replay] ->
        continuation_opts = Keyword.get(opts, :continuation_opts, [])

        with {:ok, transcript} <-
               TranscriptBuilder.from_store(store, session.id, continuation_opts) do
          context =
            session.context
            |> ensure_map()
            |> Map.put(:transcript, transcript)

          {:ok, %{session | context: context}}
        end
    end
  end

  defp resolve_continuation_mode(false), do: :disabled
  defp resolve_continuation_mode(true), do: :auto
  defp resolve_continuation_mode(:auto), do: :auto
  defp resolve_continuation_mode(:native), do: :native
  defp resolve_continuation_mode(:replay), do: :replay
  defp resolve_continuation_mode(_), do: :disabled

  defp persist_input_messages(store, run) do
    run.input
    |> extract_input_messages()
    |> Enum.reduce_while(:ok, fn message_data, :ok ->
      case emit_run_event(store, :message_sent, run, message_data) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp extract_input_messages(%{messages: messages}) when is_list(messages) do
    normalize_run_input_messages(messages)
  end

  defp extract_input_messages(%{"messages" => messages}) when is_list(messages) do
    normalize_run_input_messages(messages)
  end

  defp extract_input_messages(%{prompt: prompt}) when is_binary(prompt) and prompt != "" do
    [%{role: "user", content: prompt}]
  end

  defp extract_input_messages(%{"prompt" => prompt}) when is_binary(prompt) and prompt != "" do
    [%{role: "user", content: prompt}]
  end

  defp extract_input_messages(_), do: []

  defp normalize_run_input_messages(messages) do
    messages
    |> Enum.map(&normalize_run_input_message/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_run_input_message(message) when is_map(message) do
    role = Map.get(message, :role) || Map.get(message, "role")
    content = Map.get(message, :content) || Map.get(message, "content")
    build_input_message_event(role, content)
  end

  defp normalize_run_input_message(_), do: nil

  defp build_input_message_event(role, content) do
    normalized_content = normalize_input_message_content(content)

    if normalized_content == "" do
      nil
    else
      %{
        role: normalize_input_message_role(role),
        content: normalized_content
      }
    end
  end

  defp normalize_input_message_role(role) when role in [:system, :user, :assistant, :tool] do
    Atom.to_string(role)
  end

  defp normalize_input_message_role(role) when is_binary(role) and role != "" do
    String.downcase(role)
  end

  defp normalize_input_message_role(_), do: "user"

  defp normalize_input_message_content(nil), do: ""
  defp normalize_input_message_content(content) when is_binary(content), do: content
  defp normalize_input_message_content(content), do: inspect(content)

  defp maybe_prepare_workspace(store, run, opts) do
    workspace_opts =
      opts
      |> Keyword.get(:workspace, [])
      |> normalize_workspace_opts()

    case workspace_enabled?(workspace_opts) do
      true -> prepare_workspace_enabled(store, run, workspace_opts)
      false -> {:ok, %{enabled: false}}
    end
  end

  defp prepare_workspace_enabled(store, run, workspace_opts) do
    path = Keyword.get(workspace_opts, :path, File.cwd!())
    strategy = Keyword.get(workspace_opts, :strategy, :auto)
    backend = Workspace.backend_for_path(path, strategy: strategy)

    case Keyword.get(workspace_opts, :rollback_on_failure, false) and backend == :hash do
      true ->
        {:error,
         Error.new(
           :validation_error,
           "rollback_on_failure is only supported for git backend in MVP"
         )}

      false ->
        with {:ok, pre_snapshot} <-
               Workspace.take_snapshot(path, strategy: strategy, label: :before),
             :ok <-
               emit_run_event(store, :workspace_snapshot_taken, run, %{
                 label: :before,
                 backend: pre_snapshot.backend,
                 ref: pre_snapshot.ref
               }) do
          {:ok,
           %{
             enabled: true,
             opts: workspace_opts,
             pre_snapshot: pre_snapshot
           }}
        end
    end
  end

  defp maybe_finalize_workspace_success(_store, _run, result, %{enabled: false}) do
    {:ok, result, %{}}
  end

  defp maybe_finalize_workspace_success(store, run, result, workspace_state) do
    with {:ok, post_snapshot} <- take_post_snapshot(store, run, workspace_state, :after),
         {:ok, diff} <-
           compute_workspace_diff(
             store,
             run,
             workspace_state.pre_snapshot,
             post_snapshot,
             workspace_state.opts
           ),
         {:ok, diff} <- maybe_store_patch_artifact(diff, workspace_state.opts) do
      workspace_result = build_workspace_result(workspace_state.pre_snapshot, post_snapshot, diff)

      workspace_metadata =
        build_workspace_metadata(workspace_state.pre_snapshot, post_snapshot, diff)

      {:ok, Map.put(result, :workspace, workspace_result), %{workspace: workspace_metadata}}
    end
  end

  defp maybe_finalize_workspace_failure(_store, _run, %{enabled: false}, _error) do
    {:ok, %{}}
  end

  defp maybe_finalize_workspace_failure(store, run, workspace_state, _error) do
    with {:ok, post_snapshot} <- take_post_snapshot(store, run, workspace_state, :after_failure),
         {:ok, diff} <-
           compute_workspace_diff(
             store,
             run,
             workspace_state.pre_snapshot,
             post_snapshot,
             workspace_state.opts
           ),
         {:ok, diff} <- maybe_store_patch_artifact(diff, workspace_state.opts),
         :ok <- maybe_rollback_workspace(workspace_state) do
      workspace_metadata =
        build_workspace_metadata(workspace_state.pre_snapshot, post_snapshot, diff)

      {:ok, %{workspace: workspace_metadata}}
    end
  end

  defp take_post_snapshot(store, run, workspace_state, label) do
    path = Keyword.get(workspace_state.opts, :path, workspace_state.pre_snapshot.path)
    strategy = Keyword.get(workspace_state.opts, :strategy, :auto)

    with {:ok, post_snapshot} <- Workspace.take_snapshot(path, strategy: strategy, label: label),
         :ok <-
           emit_run_event(store, :workspace_snapshot_taken, run, %{
             label: label,
             backend: post_snapshot.backend,
             ref: post_snapshot.ref
           }) do
      {:ok, post_snapshot}
    end
  end

  defp compute_workspace_diff(
         store,
         run,
         %Snapshot{} = before_snapshot,
         %Snapshot{} = after_snapshot,
         workspace_opts
       ) do
    diff_opts = [
      capture_patch: Keyword.get(workspace_opts, :capture_patch, true),
      max_patch_bytes: Keyword.get(workspace_opts, :max_patch_bytes, 1_048_576)
    ]

    with {:ok, %Diff{} = diff} <- Workspace.diff(before_snapshot, after_snapshot, diff_opts),
         :ok <-
           emit_run_event(store, :workspace_diff_computed, run, %{
             files_changed: diff.files_changed,
             insertions: diff.insertions,
             deletions: diff.deletions,
             has_patch: is_binary(diff.patch)
           }) do
      {:ok, diff}
    end
  end

  defp maybe_rollback_workspace(workspace_state) do
    if Keyword.get(workspace_state.opts, :rollback_on_failure, false) do
      Workspace.rollback(workspace_state.pre_snapshot)
    else
      :ok
    end
  end

  # If an artifact_store is configured and a patch exists, store it as an artifact
  # and replace the patch with a patch_ref + patch_bytes in the diff metadata.
  defp maybe_store_patch_artifact(%Diff{} = diff, workspace_opts) do
    artifact_store = Keyword.get(workspace_opts, :artifact_store)

    cond do
      is_nil(artifact_store) ->
        {:ok, diff}

      is_binary(diff.patch) and diff.patch != "" ->
        patch_bytes = byte_size(diff.patch)
        random_suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

        artifact_key =
          "patch_#{diff.from_ref}_#{diff.to_ref}_#{random_suffix}"

        case ArtifactStore.put(artifact_store, artifact_key, diff.patch) do
          :ok ->
            updated_diff = %{
              diff
              | patch: nil,
                metadata:
                  diff.metadata
                  |> Map.put(:patch_ref, artifact_key)
                  |> Map.put(:patch_bytes, patch_bytes)
            }

            {:ok, updated_diff}

          {:error, _} = error ->
            error
        end

      true ->
        {:ok, diff}
    end
  end

  defp build_workspace_result(
         %Snapshot{} = before_snapshot,
         %Snapshot{} = after_snapshot,
         %Diff{} = diff
       ) do
    diff_map = Diff.to_map(diff)

    # Promote patch_ref and patch_bytes from metadata to top level for ergonomics
    diff_map =
      diff_map
      |> maybe_put(:patch_ref, diff.metadata[:patch_ref])
      |> maybe_put(:patch_bytes, diff.metadata[:patch_bytes])

    %{
      backend: diff.backend,
      before_snapshot: Snapshot.to_map(before_snapshot),
      after_snapshot: Snapshot.to_map(after_snapshot),
      diff: diff_map
    }
  end

  defp build_workspace_metadata(
         %Snapshot{} = before_snapshot,
         %Snapshot{} = after_snapshot,
         %Diff{} = diff
       ) do
    compact_diff =
      Diff.summary(diff)
      |> maybe_put(:patch, diff.patch)
      |> maybe_put(:patch_ref, diff.metadata[:patch_ref])
      |> maybe_put(:patch_bytes, diff.metadata[:patch_bytes])

    %{
      backend: diff.backend,
      before_ref: before_snapshot.ref,
      after_ref: after_snapshot.ref,
      diff: compact_diff
    }
  end

  defp normalize_workspace_opts(opts) when is_list(opts), do: opts
  defp normalize_workspace_opts(_), do: []

  defp workspace_enabled?(opts) do
    Keyword.get(opts, :enabled, false)
  end

  defp finalize_successful_run(
         store,
         run,
         session,
         result,
         provider_name,
         provider_metadata,
         extra_run_metadata
       ) do
    # Build run metadata with provider info
    run_provider_metadata =
      %{provider: provider_name}
      |> maybe_put(:provider_session_id, provider_metadata[:provider_session_id])
      |> maybe_put(:model, provider_metadata[:model])
      |> Map.merge(extra_run_metadata)

    with {:ok, updated_run} <- Run.set_output(run, result.output),
         {:ok, run_with_usage} <- Run.update_token_usage(updated_run, result.token_usage),
         run_with_provider = %{
           run_with_usage
           | provider: provider_name,
             provider_metadata: run_provider_metadata
         },
         final_run = update_run_metadata(run_with_provider, run_provider_metadata),
         updated_session = merge_session_provider_metadata(session, provider_metadata),
         execution_result = %{
           session: updated_session,
           run: final_run,
           events: [],
           provider_metadata: provider_metadata
         },
         :ok <- safe_flush(store, execution_result, :finalize_successful_run) do
      {:ok, result}
    end
  end

  defp update_run_metadata(run, new_metadata) do
    merged_metadata = Map.merge(run.metadata, new_metadata)
    %{run | metadata: merged_metadata}
  end

  defp merge_session_provider_metadata(session, provider_metadata) do
    provider_name = Map.get(session.metadata, :provider)

    # Only update if we have provider metadata to add
    metadata_to_add =
      %{}
      |> maybe_put(:provider_session_id, provider_metadata[:provider_session_id])
      |> maybe_put(:model, provider_metadata[:model])

    if map_size(metadata_to_add) > 0 do
      # Phase 2: also maintain per-provider keyed map under :provider_sessions
      existing_sessions = Map.get(session.metadata, :provider_sessions, %{})

      per_provider_entry =
        existing_sessions
        |> Map.get(provider_name, %{})
        |> Map.merge(metadata_to_add)

      provider_sessions = Map.put(existing_sessions, provider_name, per_provider_entry)

      merged_metadata =
        session.metadata
        |> Map.merge(metadata_to_add)
        |> Map.put(:provider_sessions, provider_sessions)

      %{session | metadata: merged_metadata, updated_at: DateTime.utc_now()}
    else
      session
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_keyword(keyword, _key, nil), do: keyword
  defp maybe_put_keyword(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp finalize_failed_run(store, run, error, extra_run_metadata) do
    error_code = Map.get(error, :code, :internal_error)
    error_message = Map.get(error, :message, inspect(error))
    error_map = %{code: error_code, message: error_message}

    with {:ok, failed_run} <- Run.set_error(run, error_map),
         run_with_metadata = update_run_metadata(failed_run, extra_run_metadata),
         :ok <- safe_save_run(store, run_with_metadata, :finalize_failed_run),
         :ok <- emit_run_event(store, :run_failed, run_with_metadata, %{error_code: error_code}) do
      {:error, error}
    end
  end

  @dialyzer {:nowarn_function, ensure_map: 1}
  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_), do: %{}

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
    with {:ok, event} <-
           Event.new(%{
             type: type,
             session_id: session.id,
             data: data
           }),
         {:ok, _stored_event} <- append_sequenced_event(store, event) do
      :ok
    end
  end

  defp emit_run_event(store, type, run, data \\ %{}) do
    with {:ok, event} <-
           Event.new(%{
             type: type,
             session_id: run.session_id,
             run_id: run.id,
             data: data
           }),
         {:ok, _stored_event} <- append_sequenced_event(store, event) do
      :ok
    end
  end

  defp append_sequenced_event(store, %Event{} = event) do
    safe_store_call(
      fn -> SessionStore.append_event_with_sequence(store, event) end,
      :append_event_with_sequence
    )
  end

  defp safe_get_session(store, session_id, operation) do
    safe_store_call(fn -> SessionStore.get_session(store, session_id) end, operation)
  end

  defp safe_get_run(store, run_id, operation) do
    safe_store_call(fn -> SessionStore.get_run(store, run_id) end, operation)
  end

  defp safe_save_session(store, session, operation) do
    safe_store_call(fn -> SessionStore.save_session(store, session) end, operation)
  end

  defp safe_save_run(store, run, operation) do
    safe_store_call(fn -> SessionStore.save_run(store, run) end, operation)
  end

  defp safe_flush(store, execution_result, operation) do
    safe_store_call(fn -> SessionStore.flush(store, execution_result) end, operation)
  end

  defp safe_store_call(fun, operation) when is_function(fun, 0) do
    fun.()
  catch
    :exit, reason ->
      {:error,
       Error.new(
         :storage_connection_failed,
         "SessionStore #{operation} failed because the store became unavailable",
         details: %{reason: inspect(reason)}
       )}
  end

  defp stream_wait_for_events(store, session_id, query_opts, cursor, wait_timeout_ms, poll_ms) do
    if is_integer(wait_timeout_ms) and wait_timeout_ms > 0 do
      wait_query_opts = Keyword.put(query_opts, :wait_timeout_ms, wait_timeout_ms)
      {:ok, wait_events} = SessionStore.get_events(store, session_id, wait_query_opts)
      emit_stream_events_or_idle(wait_events, cursor)
    else
      Process.sleep(poll_ms)
      {[], cursor}
    end
  end

  defp emit_stream_events_or_idle([], cursor), do: {[], cursor}

  defp emit_stream_events_or_idle(events, cursor) do
    next_cursor = advance_cursor(cursor, events)
    {events, next_cursor}
  end

  defp advance_cursor(cursor, events) do
    Enum.reduce(events, cursor, fn event, max_cursor ->
      if is_integer(event.sequence_number) do
        max(max_cursor, event.sequence_number)
      else
        max_cursor
      end
    end)
  end
end
