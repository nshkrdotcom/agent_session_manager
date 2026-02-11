defmodule AgentSessionManager.WorkflowBridge do
  @moduledoc """
  Thin integration layer for calling ASM from workflow/DAG engines.

  WorkflowBridge adapts AgentSessionManager's API into workflow-friendly
  primitives: step execution, normalized results, error classification,
  and multi-run session lifecycle management.

  This module does NOT depend on any external workflow library. It produces
  data shapes that any workflow engine (Jido, Broadway, custom) can consume.
  """

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.SessionManager
  alias AgentSessionManager.WorkflowBridge.{ErrorClassification, StepResult}

  @type store :: SessionManager.store()
  @type adapter :: SessionManager.adapter()

  @type step_params :: %{
          required(:input) => map(),
          optional(:session_id) => String.t(),
          optional(:agent_id) => String.t(),
          optional(:context) => map(),
          optional(:metadata) => map(),
          optional(:tags) => [String.t()],
          optional(:continuation) => :auto | :replay | false,
          optional(:continuation_opts) => keyword(),
          optional(:adapter_opts) => keyword(),
          optional(:policy) => map(),
          optional(:workspace) => keyword(),
          optional(:event_callback) => (map() -> any())
        }

  @doc """
  Execute a single workflow step via ASM.

  When `params.session_id` is provided, executes within an existing session
  (multi-run mode). Otherwise, creates a standalone one-shot session.

  Returns `{:ok, StepResult.t()}` or `{:error, Error.t()}`.
  """
  @spec step_execute(store(), adapter(), step_params()) ::
          {:ok, StepResult.t()} | {:error, Error.t()}
  def step_execute(store, adapter, params) do
    case Map.get(params, :session_id) do
      session_id when is_binary(session_id) and session_id != "" ->
        execute_multi_run(store, adapter, session_id, params)

      _ ->
        execute_one_shot(store, adapter, params)
    end
  end

  @doc """
  Normalize a raw ASM result map into a StepResult struct.

  Accepts either a `run_once` result (has `session_id`, `run_id`) or
  an `execute_run` result (no `session_id`/`run_id`) plus optional
  session_id and run_id overrides.
  """
  @spec step_result(map(), keyword()) :: StepResult.t()
  def step_result(raw_result, opts \\ []) when is_map(raw_result) and is_list(opts) do
    output = map_get(raw_result, :output)
    output = if is_map(output), do: output, else: %{}
    tool_calls = extract_tool_calls(output)

    %StepResult{
      output: output,
      content: extract_content(output),
      token_usage: normalize_map(map_get(raw_result, :token_usage)),
      session_id: keyword_or_map_get(opts, :session_id, raw_result),
      run_id: keyword_or_map_get(opts, :run_id, raw_result),
      events: normalize_list(map_get(raw_result, :events)),
      stop_reason: extract_stop_reason(output),
      tool_calls: tool_calls,
      has_tool_calls: tool_calls != [],
      persistence_failures: normalize_non_neg_integer(map_get(raw_result, :persistence_failures)),
      workspace: normalize_optional_map(map_get(raw_result, :workspace)),
      policy: normalize_optional_map(map_get(raw_result, :policy)),
      retryable: false
    }
  end

  @doc """
  Create and activate a shared session for a multi-step workflow.

  Returns `{:ok, session_id}` or `{:error, Error.t()}`.
  """
  @spec setup_workflow_session(store(), adapter(), map()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def setup_workflow_session(store, adapter, attrs) when is_map(attrs) do
    session_attrs =
      %{agent_id: Map.get(attrs, :agent_id, "workflow-agent")}
      |> maybe_put(:context, Map.get(attrs, :context))
      |> maybe_put(:metadata, Map.get(attrs, :metadata))
      |> maybe_put(:tags, Map.get(attrs, :tags))

    with {:ok, session} <- SessionManager.start_session(store, adapter, session_attrs),
         {:ok, _active} <- SessionManager.activate_session(store, session.id) do
      {:ok, session.id}
    end
  end

  @doc """
  Complete or fail a shared workflow session.

  With default opts, completes the session. Pass `status: :failed` and
  optionally `error: %Error{}` to fail it.

  Returns `:ok` or `{:error, Error.t()}`.
  """
  @spec complete_workflow_session(store(), String.t(), keyword()) ::
          :ok | {:error, Error.t()}
  def complete_workflow_session(store, session_id, opts \\ [])
      when is_binary(session_id) and is_list(opts) do
    status = Keyword.get(opts, :status, :completed)

    case status do
      :failed ->
        error = normalize_error(Keyword.get(opts, :error))

        case SessionManager.fail_session(store, session_id, error) do
          {:ok, _session} -> :ok
          {:error, %Error{} = asm_error} -> {:error, asm_error}
        end

      _ ->
        case SessionManager.complete_session(store, session_id) do
          {:ok, _session} -> :ok
          {:error, %Error{} = asm_error} -> {:error, asm_error}
        end
    end
  end

  @doc """
  Classify an ASM error for workflow routing decisions.

  Returns an `ErrorClassification` struct with:
  - `retryable` - whether the error is retryable
  - `category` - error category atom
  - `recommended_action` - :retry, :failover, :wait_and_retry, :abort, or :cancel
  """
  @spec classify_error(Error.t()) :: ErrorClassification.t()
  def classify_error(%Error{} = error) do
    retryable = Error.retryable?(error)
    category = Error.category(error.code)

    %ErrorClassification{
      error: error,
      retryable: retryable,
      category: category,
      recommended_action: recommended_action(error.code)
    }
  end

  defp execute_one_shot(store, adapter, params) do
    if module_backed_store?(store) do
      execute_one_shot_via_multi_step(store, adapter, params)
    else
      case SessionManager.run_once(store, adapter, params.input, build_run_once_opts(params)) do
        {:ok, raw_result} -> {:ok, step_result(raw_result)}
        {:error, %Error{} = error} -> {:error, error}
      end
    end
  end

  defp execute_one_shot_via_multi_step(store, adapter, params) do
    session_attrs =
      %{agent_id: Map.get(params, :agent_id, "workflow-agent")}
      |> maybe_put(:context, Map.get(params, :context))
      |> maybe_put(:metadata, Map.get(params, :metadata))
      |> maybe_put(:tags, Map.get(params, :tags))

    with {:ok, session} <- SessionManager.start_session(store, adapter, session_attrs),
         {:ok, _active} <- SessionManager.activate_session(store, session.id) do
      case SessionManager.start_run(store, adapter, session.id, params.input) do
        {:ok, run} -> execute_one_shot_run(store, adapter, session.id, run.id, params)
        {:error, %Error{} = error} -> fail_session_and_return(store, session.id, error)
      end
    end
  end

  defp execute_one_shot_run(store, adapter, session_id, run_id, params) do
    case SessionManager.execute_run(store, adapter, run_id, build_exec_opts(params)) do
      {:ok, raw_result} ->
        case SessionManager.complete_session(store, session_id) do
          {:ok, _session} ->
            {:ok, step_result(raw_result, session_id: session_id, run_id: run_id)}

          {:error, %Error{} = error} ->
            {:error, error}
        end

      {:error, %Error{} = error} ->
        fail_session_and_return(store, session_id, error)
    end
  end

  defp execute_multi_run(store, adapter, session_id, params) do
    with {:ok, run} <- SessionManager.start_run(store, adapter, session_id, params.input),
         {:ok, raw_result} <-
           SessionManager.execute_run(store, adapter, run.id, build_exec_opts(params)) do
      {:ok, step_result(raw_result, session_id: session_id, run_id: run.id)}
    end
  end

  defp fail_session_and_return(store, session_id, error) do
    _ = SessionManager.fail_session(store, session_id, error)
    {:error, error}
  end

  defp module_backed_store?({module, _context}) when is_atom(module), do: true
  defp module_backed_store?(_), do: false

  defp build_run_once_opts(params) do
    []
    |> maybe_put_keyword(:agent_id, Map.get(params, :agent_id))
    |> maybe_put_keyword(:metadata, Map.get(params, :metadata))
    |> maybe_put_keyword(:context, Map.get(params, :context))
    |> maybe_put_keyword(:tags, Map.get(params, :tags))
    |> maybe_put_keyword(:event_callback, Map.get(params, :event_callback))
    |> maybe_put_keyword(:continuation, Map.get(params, :continuation))
    |> maybe_put_keyword(:continuation_opts, Map.get(params, :continuation_opts))
    |> maybe_put_keyword(:adapter_opts, Map.get(params, :adapter_opts))
    |> maybe_put_keyword(:policy, Map.get(params, :policy))
    |> maybe_put_keyword(:workspace, Map.get(params, :workspace))
  end

  defp build_exec_opts(params) do
    []
    |> maybe_put_keyword(:event_callback, Map.get(params, :event_callback))
    |> maybe_put_keyword(:continuation, Map.get(params, :continuation))
    |> maybe_put_keyword(:continuation_opts, Map.get(params, :continuation_opts))
    |> maybe_put_keyword(:adapter_opts, Map.get(params, :adapter_opts))
    |> maybe_put_keyword(:policy, Map.get(params, :policy))
    |> maybe_put_keyword(:workspace, Map.get(params, :workspace))
  end

  defp recommended_action(:provider_timeout), do: :retry
  defp recommended_action(:provider_rate_limited), do: :wait_and_retry
  defp recommended_action(:provider_unavailable), do: :failover
  defp recommended_action(:storage_connection_failed), do: :retry
  defp recommended_action(:timeout), do: :retry
  defp recommended_action(:provider_error), do: :abort
  defp recommended_action(:provider_authentication_failed), do: :abort
  defp recommended_action(:provider_quota_exceeded), do: :abort
  defp recommended_action(:validation_error), do: :abort
  defp recommended_action(:session_not_found), do: :abort
  defp recommended_action(:run_not_found), do: :abort
  defp recommended_action(:cancelled), do: :cancel
  defp recommended_action(:policy_violation), do: :cancel
  defp recommended_action(:max_runs_exceeded), do: :wait_and_retry
  defp recommended_action(_), do: :abort

  defp keyword_or_map_get(opts, key, map) when is_list(opts) and is_map(map) do
    case Keyword.get(opts, key) do
      nil -> map_get(map, key)
      value -> value
    end
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_map(value) when is_map(value), do: value
  defp normalize_map(_), do: %{}

  defp normalize_optional_map(nil), do: nil
  defp normalize_optional_map(value) when is_map(value), do: value
  defp normalize_optional_map(_), do: nil

  defp normalize_list(value) when is_list(value), do: value
  defp normalize_list(_), do: []

  defp normalize_non_neg_integer(value) when is_integer(value) and value >= 0, do: value
  defp normalize_non_neg_integer(_), do: 0

  defp extract_content(output) when is_map(output) do
    case map_get(output, :content) do
      content when is_binary(content) -> content
      _ -> nil
    end
  end

  defp extract_stop_reason(output) when is_map(output) do
    case map_get(output, :stop_reason) do
      reason when is_binary(reason) -> reason
      reason when is_atom(reason) -> Atom.to_string(reason)
      _ -> nil
    end
  end

  defp extract_tool_calls(output) when is_map(output) do
    case map_get(output, :tool_calls) do
      tool_calls when is_list(tool_calls) -> tool_calls
      _ -> []
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_keyword(keyword, _key, nil), do: keyword
  defp maybe_put_keyword(keyword, key, value), do: Keyword.put(keyword, key, value)

  defp normalize_error(%Error{} = error), do: error
  defp normalize_error(_), do: Error.new(:internal_error, "Workflow failed")
end
