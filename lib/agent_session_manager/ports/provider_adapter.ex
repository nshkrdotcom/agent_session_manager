defmodule AgentSessionManager.Ports.ProviderAdapter do
  @moduledoc """
  Port (interface) for AI provider adapters.

  This behaviour defines the contract that all provider adapter implementations
  must fulfill. It follows the ports and adapters pattern, allowing different
  AI providers (Anthropic, OpenAI, etc.) to be swapped without changing the
  core business logic.

  ## Design Principles

  - **Provider-agnostic**: Core logic doesn't depend on provider specifics
  - **Capability-based**: Adapters declare what they support
  - **Event-driven**: Execution emits normalized events via callbacks
  - **Cancellable**: Long-running operations can be cancelled

  ## Implementation Requirements

  Implementations must:

  1. Return a unique provider name
  2. Declare supported capabilities
  3. Execute runs and emit events via callback
  4. Support cancellation of in-progress runs
  5. Validate provider-specific configuration

  ## Event Emission

  During `execute/4`, adapters should call the `:event_callback` option (if provided)
  with normalized event maps containing:

  - `:type` - Event type (e.g., `:run_started`, `:message_received`)
  - `:session_id` - The session ID
  - `:run_id` - The run ID
  - `:data` - Event-specific payload
  - `:timestamp` - When the event occurred

  ## Usage

  Adapters are typically used through the SessionManager:

      # The SessionManager handles adapter lifecycle
      {:ok, manager} = SessionManager.start_link(
        adapter: MyAdapter,
        adapter_opts: [api_key: "..."]
      )

      # Or directly for testing
      {:ok, adapter} = MyAdapter.start_link(api_key: "...")
      {:ok, capabilities} = ProviderAdapter.capabilities(adapter)
      {:ok, result} = ProviderAdapter.execute(adapter, run, session, event_callback: fn e -> ... end)

  """

  alias AgentSessionManager.Config
  alias AgentSessionManager.Core.{Capability, Error, Run, Session}
  alias AgentSessionManager.Runtime.ExitReasons

  @type adapter :: GenServer.server() | pid() | atom() | module()
  @type run_result :: %{
          output: map(),
          token_usage: map(),
          events: [map()]
        }
  @type execute_opts :: [
          {:event_callback, (map() -> any())} | {:timeout, pos_integer()}
        ]

  # ============================================================================
  # Behaviour Callbacks
  # ============================================================================

  @doc """
  Returns the unique name of this provider.

  This name is used for logging, metrics, and identifying the provider
  in multi-provider configurations.

  ## Examples

      iex> MyAdapter.name(adapter)
      "anthropic"

  """
  @callback name(adapter()) :: String.t()

  @doc """
  Returns the list of capabilities supported by this provider.

  Capabilities define what the provider can do - tools, resources,
  sampling modes, etc. The SessionManager uses this to validate
  that required capabilities are available before starting runs.

  ## Returns

  - `{:ok, [Capability.t()]}` - List of supported capabilities
  - `{:error, Error.t()}` - If capabilities cannot be determined

  ## Examples

      iex> MyAdapter.capabilities(adapter)
      {:ok, [
        %Capability{name: "chat", type: :tool, enabled: true},
        %Capability{name: "sampling", type: :sampling, enabled: true}
      ]}

  """
  @callback capabilities(adapter()) :: {:ok, [Capability.t()]} | {:error, Error.t()}

  @doc """
  Executes a run against the AI provider.

  This is the main execution entry point. The adapter should:

  1. Emit a `:run_started` event
  2. Send the request to the provider
  3. Emit events as responses come in (`:message_received`, `:tool_call_started`, etc.)
  4. Emit `:run_completed` or `:run_failed` when done
  5. Return the final result

  ## Parameters

  - `adapter` - The adapter instance
  - `run` - The run to execute (contains input, session_id, etc.)
  - `session` - The parent session (contains context, metadata)
  - `opts` - Execution options:
    - `:event_callback` - Function called for each event emitted
    - `:timeout` - Maximum execution time in milliseconds

  ## Returns

  - `{:ok, result}` - Execution completed successfully
    - `result.output` - The final output from the provider
    - `result.token_usage` - Token usage statistics
    - `result.events` - All events emitted during execution
  - `{:error, Error.t()}` - Execution failed

  ## Examples

      iex> callback = fn event -> Logger.info("Event: \#{inspect(event)}") end
      iex> MyAdapter.execute(adapter, run, session, event_callback: callback)
      {:ok, %{
        output: %{content: "Hello!"},
        token_usage: %{input_tokens: 10, output_tokens: 20},
        events: [...]
      }}

  """
  @callback execute(adapter(), Run.t(), Session.t(), execute_opts()) ::
              {:ok, run_result()} | {:error, Error.t()}

  @doc """
  Cancels an in-progress run.

  Providers should attempt to gracefully cancel the run. After cancellation,
  the run should emit a `:run_cancelled` event.

  ## Parameters

  - `adapter` - The adapter instance
  - `run_id` - The ID of the run to cancel

  ## Returns

  - `{:ok, run_id}` - Cancellation initiated (run will emit cancelled event)
  - `{:error, Error.t()}` - Cancellation failed

  ## Examples

      iex> MyAdapter.cancel(adapter, "run_123")
      {:ok, "run_123"}

  """
  @callback cancel(adapter(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}

  @doc """
  Validates provider-specific configuration.

  This is called before the adapter starts to ensure all required
  configuration is present and valid.

  ## Parameters

  - `adapter` - The adapter instance (or module for static validation)
  - `config` - Configuration map to validate

  ## Returns

  - `:ok` - Configuration is valid
  - `{:error, Error.t()}` - Configuration is invalid

  ## Examples

      iex> MyAdapter.validate_config(adapter, %{api_key: "sk-..."})
      :ok

      iex> MyAdapter.validate_config(adapter, %{})
      {:error, %Error{code: :validation_error, message: "api_key is required"}}

  """
  @callback validate_config(adapter() | module(), map()) :: :ok | {:error, Error.t()}

  # ============================================================================
  # Default Implementations
  # ============================================================================

  @doc """
  Returns the provider name.
  """
  @spec name(adapter()) :: String.t()
  def name(adapter) when is_atom(adapter), do: adapter.name(adapter)

  def name(adapter) do
    GenServer.call(adapter, :name)
  end

  @doc """
  Returns the list of capabilities.
  """
  @spec capabilities(adapter()) :: {:ok, [Capability.t()]} | {:error, Error.t()}
  def capabilities(adapter) when is_atom(adapter) and not is_nil(adapter) do
    call_registered_or_fallback(
      adapter,
      :capabilities,
      fn -> adapter.capabilities(adapter) end,
      5_000,
      :capabilities
    )
  end

  def capabilities(adapter) do
    call_with_error(adapter, :capabilities, 5_000, :capabilities)
  end

  @doc """
  Executes a run.
  """
  @spec execute(adapter(), Run.t(), Session.t(), execute_opts()) ::
          {:ok, run_result()} | {:error, Error.t()}
  def execute(adapter, run, session, opts \\ [])

  def execute(adapter, run, session, opts) when is_atom(adapter) and not is_nil(adapter) do
    call_registered_or_fallback(
      adapter,
      {:execute, run, session, opts},
      fn ->
        adapter.execute(adapter, run, session, opts)
      end,
      resolve_execute_timeout(opts),
      :execute
    )
  end

  def execute(adapter, run, session, opts) do
    timeout = resolve_execute_timeout(opts)
    call_with_error(adapter, {:execute, run, session, opts}, timeout, :execute)
  end

  @doc """
  Cancels a run.
  """
  @spec cancel(adapter(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def cancel(adapter, run_id) when is_atom(adapter) and not is_nil(adapter) do
    call_registered_or_fallback(
      adapter,
      {:cancel, run_id},
      fn -> adapter.cancel(adapter, run_id) end,
      5_000,
      :cancel
    )
  end

  def cancel(adapter, run_id) do
    call_with_error(adapter, {:cancel, run_id}, 5_000, :cancel)
  end

  @doc """
  Validates configuration.
  """
  @spec validate_config(adapter() | module(), map()) :: :ok | {:error, Error.t()}
  def validate_config(adapter, config) when is_atom(adapter) do
    adapter.validate_config(adapter, config)
  end

  def validate_config(adapter, config) do
    call_with_error(
      adapter,
      {:validate_config, config},
      Config.get(:genserver_call_timeout_ms),
      :validate_config
    )
  end

  @doc """
  Resolves execute call timeout from options, including a grace period for
  asynchronous result handoff back to callers.
  """
  @spec resolve_execute_timeout(keyword()) :: pos_integer()
  def resolve_execute_timeout(opts) do
    Keyword.get(opts, :timeout, Config.get(:execute_timeout_ms)) +
      Config.get(:execute_grace_timeout_ms)
  end

  defp call_registered_or_fallback(adapter, request, fallback, timeout, operation) do
    GenServer.call(adapter, request, timeout)
  catch
    :exit, reason ->
      if missing_registered_process_reason?(reason) do
        fallback.()
      else
        {:error, call_exit_error(operation, adapter, reason, timeout)}
      end
  end

  defp call_with_error(adapter, request, timeout, operation) do
    GenServer.call(adapter, request, timeout)
  catch
    :exit, reason ->
      {:error, call_exit_error(operation, adapter, reason, timeout)}
  end

  defp call_exit_error(operation, adapter, reason, timeout) do
    {code, message} =
      cond do
        timeout_exit_reason?(reason) ->
          {
            :provider_timeout,
            "Provider #{operation} call timed out after #{timeout}ms"
          }

        ExitReasons.adapter_unavailable?(reason) ->
          {
            :provider_unavailable,
            "Provider #{operation} call failed because adapter is unavailable"
          }

        true ->
          {
            :provider_error,
            "Provider #{operation} call failed: #{inspect(reason)}"
          }
      end

    Error.new(code, message,
      details: %{
        operation: operation,
        adapter: inspect(adapter),
        timeout_ms: timeout,
        exit_reason: inspect(reason)
      }
    )
  end

  defp timeout_exit_reason?(:timeout), do: true
  defp timeout_exit_reason?({:timeout, _}), do: true
  defp timeout_exit_reason?(_), do: false

  defp missing_registered_process_reason?(:noproc), do: true
  defp missing_registered_process_reason?({:noproc, _}), do: true
  defp missing_registered_process_reason?({:shutdown, {:noproc, _}}), do: true
  defp missing_registered_process_reason?(_), do: false
end
