defmodule AgentSessionManager.Adapters.AmpAdapter do
  @moduledoc """
  Provider adapter for Amp (Sourcegraph) AI agent integration.

  This adapter implements the `ProviderAdapter` behaviour and provides:

  - Streaming execution via AmpSdk.execute/2
  - Tool use support with proper event mapping
  - Interrupt/cancel capability
  - Accurate capability advertisement

  ## Event Mapping

  Amp SDK message types are mapped to normalized events as follows:

  | Amp Message              | Normalized Event        | Notes                              |
  |--------------------------|-------------------------|------------------------------------|
  | SystemMessage            | run_started             | Signals execution has begun        |
  | AssistantMessage (text)  | message_streamed        | Each text block emits a stream     |
  | AssistantMessage (tool)  | tool_call_started       | Tool invocation requested          |
  | UserMessage (result, ok) | tool_call_completed     | Tool finished successfully         |
  | UserMessage (result, err)| tool_call_failed        | Tool failed with error             |
  | ResultMessage            | message_received,       | Emits full message then completion |
  |                          | token_usage_updated,    |                                    |
  |                          | run_completed           |                                    |
  | ErrorResultMessage       | error_occurred,         | Error handling                     |
  |                          | run_failed              |                                    |

  ## Usage

  ```elixir
  {:ok, adapter} = AmpAdapter.start_link(cwd: "/path/to/project")
  {:ok, capabilities} = AmpAdapter.capabilities(adapter)

  {:ok, session} = Session.new(%{agent_id: "my-agent"})
  {:ok, run} = Run.new(%{session_id: session.id, input: "Hello"})

  {:ok, result} = AmpAdapter.execute(adapter, run, session,
    event_callback: fn event -> IO.inspect(event) end
  )
  ```

  ## Configuration

  Required:
  - `:cwd` - Working directory for Amp operations

  Optional:
  - `:mode` - Execution mode (default: "smart")
  - `:permissions` - Permission rules for tool access
  - `:mcp_config` - MCP server configuration
  - `:thinking` - Enable thinking mode (default: false)
  - `:sdk_module` - SDK module for testing (default: real Amp SDK)
  - `:sdk_pid` - SDK process for testing
  """

  @behaviour AgentSessionManager.Ports.ProviderAdapter

  use GenServer

  alias AgentSessionManager.Core.{Capability, Error}
  alias AgentSessionManager.Ports.ProviderAdapter

  alias AmpSdk.Transport

  alias AmpSdk.Types.{
    AssistantMessage,
    ErrorResultMessage,
    ResultMessage,
    SystemMessage,
    TextContent,
    ToolResultContent,
    ToolUseContent,
    UserMessage
  }

  @emitted_events_key {__MODULE__, :emitted_events}

  defmodule RunState do
    @moduledoc false
    @enforce_keys [:run, :from, :task_ref, :task_pid]
    @type t :: %__MODULE__{
            run: map(),
            from: GenServer.from(),
            task_ref: reference(),
            task_pid: pid(),
            cancelled: boolean(),
            transport_pid: pid() | nil
          }
    defstruct [
      :run,
      :from,
      :task_ref,
      :task_pid,
      cancelled: false,
      transport_pid: nil
    ]
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the Amp adapter.

  ## Options

  - `:cwd` - Required. The working directory for Amp operations.
  - `:mode` - Optional. Execution mode (default: "smart").
  - `:permissions` - Optional. Permission rules.
  - `:mcp_config` - Optional. MCP server configuration.
  - `:thinking` - Optional. Enable thinking mode.
  - `:sdk_module` - Optional. Mock SDK module for testing.
  - `:sdk_pid` - Optional. Mock SDK process for testing.
  - `:name` - Optional. GenServer name for registration.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, _cwd} <- extract_cwd(opts) do
      {name, opts} = Keyword.pop(opts, :name)

      if name do
        GenServer.start_link(__MODULE__, opts, name: name)
      else
        GenServer.start_link(__MODULE__, opts)
      end
    end
  end

  @doc """
  Stops the adapter.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # ============================================================================
  # ProviderAdapter Behaviour Implementation
  # ============================================================================

  @impl AgentSessionManager.Ports.ProviderAdapter
  def name(_adapter), do: "amp"

  @impl AgentSessionManager.Ports.ProviderAdapter
  def capabilities(adapter) when is_pid(adapter) or is_atom(adapter) do
    GenServer.call(adapter, :capabilities)
  end

  @impl AgentSessionManager.Ports.ProviderAdapter
  def execute(adapter, run, session, opts \\ []) do
    timeout = ProviderAdapter.resolve_execute_timeout(opts)
    GenServer.call(adapter, {:execute, run, session, opts}, timeout)
  end

  @impl AgentSessionManager.Ports.ProviderAdapter
  def cancel(adapter, run_id) do
    GenServer.call(adapter, {:cancel, run_id})
  end

  @impl AgentSessionManager.Ports.ProviderAdapter
  def validate_config(_adapter, config) do
    cond do
      not Map.has_key?(config, :cwd) ->
        {:error, Error.new(:validation_error, "cwd is required")}

      config.cwd == "" ->
        {:error, Error.new(:validation_error, "cwd cannot be empty")}

      true ->
        :ok
    end
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl GenServer
  def init(opts) do
    case extract_cwd(opts) do
      {:ok, cwd} ->
        {:ok, task_supervisor} = Task.Supervisor.start_link()

        state = %{
          cwd: cwd,
          mode: Keyword.get(opts, :mode, "smart"),
          permissions: Keyword.get(opts, :permissions),
          mcp_config: Keyword.get(opts, :mcp_config),
          thinking: Keyword.get(opts, :thinking, false),
          sdk_module: Keyword.get(opts, :sdk_module),
          sdk_pid: Keyword.get(opts, :sdk_pid),
          task_supervisor: task_supervisor,
          active_runs: %{},
          task_refs: %{},
          capabilities: build_capabilities()
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:name, _from, state) do
    {:reply, "amp", state}
  end

  @impl GenServer
  def handle_call(:capabilities, _from, state) do
    {:reply, {:ok, state.capabilities}, state}
  end

  @impl GenServer
  def handle_call({:execute, run, session, opts}, from, state) do
    adapter_pid = self()

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        safe_do_execute(state, run, session, opts, adapter_pid)
      end)

    run_state = %RunState{
      run: run,
      from: from,
      cancelled: false,
      task_pid: task.pid,
      task_ref: task.ref,
      transport_pid: nil
    }

    new_state = %{
      state
      | active_runs: Map.put(state.active_runs, run.id, run_state),
        task_refs: Map.put(state.task_refs, task.ref, {run.id, from})
    }

    {:noreply, new_state}
  end

  @impl GenServer
  def handle_call({:cancel, run_id}, _from, state) do
    case Map.get(state.active_runs, run_id) do
      nil ->
        {:reply, {:error, Error.new(:run_not_found, "Run not found: #{run_id}")}, state}

      run_state ->
        new_run_state = %{run_state | cancelled: true}

        new_state = %{
          state
          | active_runs: Map.put(state.active_runs, run_id, new_run_state)
        }

        # Try to cancel via mock SDK if available
        if state.sdk_module && state.sdk_pid do
          state.sdk_module.cancel(state.sdk_pid)
        end

        # Try to close transport if available
        if run_state.transport_pid do
          try do
            Transport.Erlexec.close(run_state.transport_pid)
          catch
            _, _ -> :ok
          end
        end

        # Send cancellation notification to the worker process
        if run_state.task_pid do
          send(run_state.task_pid, {:cancelled_notification, run_id})
        end

        {:reply, {:ok, run_id}, new_state}
    end
  end

  @impl GenServer
  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    case Map.pop(state.task_refs, task_ref) do
      {nil, _refs} ->
        {:noreply, state}

      {{run_id, from}, new_task_refs} ->
        Process.demonitor(task_ref, [:flush])
        GenServer.reply(from, result)

        new_active_runs =
          case Map.get(state.active_runs, run_id) do
            %RunState{task_ref: ^task_ref} -> Map.delete(state.active_runs, run_id)
            _ -> state.active_runs
          end

        {:noreply, %{state | active_runs: new_active_runs, task_refs: new_task_refs}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, task_ref, :process, _pid, reason}, state) do
    case Map.pop(state.task_refs, task_ref) do
      {nil, _refs} ->
        {:noreply, state}

      {{run_id, from}, new_task_refs} ->
        error =
          Error.new(
            :internal_error,
            "Execution worker exited before returning a result: #{inspect(reason)}"
          )

        GenServer.reply(from, {:error, error})

        new_active_runs =
          case Map.get(state.active_runs, run_id) do
            %RunState{task_ref: ^task_ref} -> Map.delete(state.active_runs, run_id)
            _ -> state.active_runs
          end

        {:noreply, %{state | active_runs: new_active_runs, task_refs: new_task_refs}}
    end
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp extract_cwd(opts) do
    case Keyword.fetch(opts, :cwd) do
      {:ok, cwd} when is_binary(cwd) and cwd != "" ->
        {:ok, cwd}

      {:ok, ""} ->
        {:error, Error.new(:validation_error, "cwd cannot be empty")}

      {:ok, _} ->
        {:error, Error.new(:validation_error, "cwd must be a non-empty string")}

      :error ->
        {:error, Error.new(:validation_error, "cwd is required")}
    end
  end

  defp safe_do_execute(state, run, session, opts, adapter_pid) do
    do_execute(state, run, session, opts, adapter_pid)
  rescue
    exception ->
      {:error, Error.new(:internal_error, Exception.message(exception))}
  catch
    kind, reason ->
      {:error, Error.new(:internal_error, "Execution failed (#{kind}): #{inspect(reason)}")}
  end

  defp do_execute(state, run, session, opts, _adapter_pid) do
    event_callback = Keyword.get(opts, :event_callback)
    reset_emitted_events()

    ctx = %{
      run: run,
      session: session,
      event_callback: event_callback,
      accumulated_content: "",
      tool_calls: [],
      token_usage: %{input_tokens: 0, output_tokens: 0},
      session_id: nil
    }

    case state.sdk_module do
      nil ->
        execute_with_real_sdk(state, ctx)

      sdk_module ->
        execute_with_mock_sdk(sdk_module, state.sdk_pid, ctx, state)
    end
  end

  defp execute_with_real_sdk(state, ctx) do
    options = build_amp_options(state)
    prompt = extract_prompt(ctx.run.input)
    events_stream = AmpSdk.execute(prompt, options)

    events_stream
    |> Enum.reduce_while(ctx, &process_single_message/2)
    |> handle_stream_result()
  end

  defp execute_with_mock_sdk(sdk_module, sdk_pid, ctx, _state) do
    events_stream = sdk_module.execute(sdk_pid, ctx.run.input, %{})

    events_stream
    |> Enum.reduce_while(ctx, &process_single_message/2)
    |> handle_stream_result()
  end

  defp process_single_message(message, acc_ctx) do
    if cancelled?() do
      emit_event(acc_ctx, :run_cancelled, %{})
      {:halt, {:cancelled, acc_ctx}}
    else
      process_message_uncancelled(message, acc_ctx)
    end
  end

  defp cancelled? do
    receive do
      {:cancelled_notification, _run_id} -> true
    after
      0 -> false
    end
  end

  defp process_message_uncancelled(message, acc_ctx) do
    new_ctx = handle_amp_message(message, acc_ctx)

    case classify_message(message) do
      :error -> {:halt, {:error, message, new_ctx}}
      :continue -> {:cont, new_ctx}
    end
  end

  defp classify_message(%ErrorResultMessage{}), do: :error
  defp classify_message(_), do: :continue

  defp handle_stream_result({:error, error_msg, error_ctx}) do
    error_message = extract_error_message(error_msg)
    permission_denials = extract_permission_denials(error_msg)

    emit_event(error_ctx, :error_occurred, %{
      error_code: :provider_error,
      error_message: error_message,
      permission_denials: permission_denials
    })

    emit_event(error_ctx, :run_failed, %{
      error_code: :provider_error,
      error_message: error_message
    })

    {:error, Error.new(:provider_error, error_message)}
  end

  defp handle_stream_result({:cancelled, cancelled_ctx}) do
    emit_event(cancelled_ctx, :run_cancelled, %{})
    {:error, Error.new(:cancelled, "Run was cancelled")}
  end

  defp handle_stream_result(success_ctx), do: build_result(success_ctx)

  defp extract_error_message(%ErrorResultMessage{error: error}), do: error
  defp extract_error_message(_), do: "Unknown error"

  defp extract_permission_denials(%ErrorResultMessage{permission_denials: denials}), do: denials
  defp extract_permission_denials(_), do: nil

  # ============================================================================
  # Message Handlers
  # ============================================================================

  defp handle_amp_message(%SystemMessage{} = msg, ctx) do
    emit_event(ctx, :run_started, %{
      session_id: msg.session_id,
      tools: msg.tools,
      cwd: msg.cwd,
      mcp_servers: msg.mcp_servers
    })

    %{ctx | session_id: msg.session_id}
  end

  defp handle_amp_message(%AssistantMessage{message: payload} = _msg, ctx) do
    Enum.reduce(payload.content, ctx, fn content_block, acc ->
      handle_content_block(content_block, payload, acc)
    end)
  end

  defp handle_amp_message(%UserMessage{message: payload} = _msg, ctx) do
    Enum.reduce(payload.content, ctx, fn content_block, acc ->
      handle_user_content_block(content_block, acc)
    end)
  end

  defp handle_amp_message(%ResultMessage{} = msg, ctx) do
    # Emit message_received with accumulated content
    emit_event(ctx, :message_received, %{
      content: ctx.accumulated_content,
      role: "assistant"
    })

    # Update final token usage
    final_ctx = update_token_usage(ctx, msg.usage)

    # Emit token_usage_updated
    emit_event(final_ctx, :token_usage_updated, %{
      input_tokens: final_ctx.token_usage.input_tokens,
      output_tokens: final_ctx.token_usage.output_tokens
    })

    # Emit run_completed
    emit_event(final_ctx, :run_completed, %{
      stop_reason: "end_turn",
      duration_ms: msg.duration_ms,
      num_turns: msg.num_turns,
      token_usage: final_ctx.token_usage
    })

    final_ctx
  end

  defp handle_amp_message(%ErrorResultMessage{}, ctx) do
    # Error handling is done in handle_stream_result via the halt
    ctx
  end

  defp handle_amp_message(_unknown, ctx) do
    # Unknown message type, ignore
    ctx
  end

  # ============================================================================
  # Content Block Handlers
  # ============================================================================

  defp handle_content_block(%TextContent{text: text}, payload, ctx) when text != "" do
    emit_event(ctx, :message_streamed, %{
      content: text,
      delta: text
    })

    # Update per-turn token usage if available
    new_ctx = update_token_usage(ctx, payload.usage)
    %{new_ctx | accumulated_content: new_ctx.accumulated_content <> text}
  end

  defp handle_content_block(%ToolUseContent{} = tool, _payload, ctx) do
    emit_event(ctx, :tool_call_started, %{
      call_id: tool.id,
      tool_name: tool.name,
      input: tool.input
    })

    tool_call = %{
      id: tool.id,
      name: tool.name,
      input: tool.input
    }

    %{ctx | tool_calls: ctx.tool_calls ++ [tool_call]}
  end

  defp handle_content_block(_other, _payload, ctx), do: ctx

  defp handle_user_content_block(%ToolResultContent{is_error: true} = result, ctx) do
    emit_event(ctx, :tool_call_failed, %{
      tool_use_id: result.tool_use_id,
      content: result.content,
      is_error: true
    })

    ctx
  end

  defp handle_user_content_block(%ToolResultContent{is_error: false} = result, ctx) do
    emit_event(ctx, :tool_call_completed, %{
      tool_use_id: result.tool_use_id,
      content: result.content
    })

    ctx
  end

  defp handle_user_content_block(_other, ctx), do: ctx

  # ============================================================================
  # Helpers
  # ============================================================================

  defp update_token_usage(ctx, nil), do: ctx

  defp update_token_usage(ctx, %{input_tokens: input, output_tokens: output}) do
    %{ctx | token_usage: %{input_tokens: input, output_tokens: output}}
  end

  defp update_token_usage(ctx, _), do: ctx

  defp build_amp_options(state) do
    %AmpSdk.Types.Options{
      cwd: state.cwd,
      mode: state.mode || "smart",
      permissions: state.permissions,
      mcp_config: state.mcp_config,
      thinking: state.thinking || false
    }
  end

  defp extract_prompt(input) when is_binary(input), do: input

  defp extract_prompt(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.filter(fn msg -> msg[:role] == "user" || msg["role"] == "user" end)
    |> Enum.map_join("\n", fn msg -> msg[:content] || msg["content"] || "" end)
  end

  defp extract_prompt(input), do: inspect(input)

  defp emit_event(ctx, type, data) do
    event = %{
      type: type,
      timestamp: DateTime.utc_now(),
      session_id: ctx.session.id,
      run_id: ctx.run.id,
      data: data,
      provider: :amp
    }

    if ctx.event_callback do
      ctx.event_callback.(event)
    end

    append_emitted_event(event)
    event
  end

  defp build_result(ctx) do
    output = %{
      content: ctx.accumulated_content,
      tool_calls: ctx.tool_calls
    }

    {:ok,
     %{
       output: output,
       token_usage: ctx.token_usage,
       events: emitted_events()
     }}
  end

  defp reset_emitted_events do
    Process.put(@emitted_events_key, [])
  end

  defp append_emitted_event(event) do
    events = Process.get(@emitted_events_key, [])
    Process.put(@emitted_events_key, [event | events])
  end

  defp emitted_events do
    @emitted_events_key
    |> Process.get([])
    |> Enum.reverse()
  end

  defp build_capabilities do
    [
      %Capability{
        name: "streaming",
        type: :sampling,
        enabled: true,
        description: "Real-time streaming of responses"
      },
      %Capability{
        name: "tool_use",
        type: :tool,
        enabled: true,
        description: "Tool/function calling capability"
      },
      %Capability{
        name: "interrupt",
        type: :sampling,
        enabled: true,
        description: "Ability to interrupt/cancel in-progress requests"
      },
      %Capability{
        name: "mcp",
        type: :tool,
        enabled: true,
        description: "MCP server integration"
      },
      %Capability{
        name: "file_operations",
        type: :tool,
        enabled: true,
        description: "File read/write operations"
      },
      %Capability{
        name: "bash",
        type: :tool,
        enabled: true,
        description: "Command execution capability"
      }
    ]
  end
end
