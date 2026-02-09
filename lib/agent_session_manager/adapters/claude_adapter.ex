defmodule AgentSessionManager.Adapters.ClaudeAdapter do
  @moduledoc """
  Provider adapter for Claude (Anthropic) AI models.

  This adapter implements the `ProviderAdapter` behaviour and provides:

  - Streaming message execution with real-time event emission
  - Tool use support with proper event mapping
  - Interrupt/cancel capability
  - Accurate capability advertisement

  ## Event Mapping

  Claude Streaming API events are mapped to normalized events as follows:

  | Streaming Event       | Normalized Event       | Notes                              |
  |-----------------------|------------------------|------------------------------------|
  | message_start         | run_started            | Signals execution has begun        |
  | text_delta            | message_streamed       | Each token-level delta streams out |
  | tool_use_start        | tool_call_started      | Tool invocation begins             |
  | message_delta         | token_usage_updated    | Final usage stats and stop reason  |
  | message_stop          | message_received,      | Emits full message then completion |
  |                       | run_completed          |                                    |

  ## Usage

  ```elixir
  {:ok, adapter} = ClaudeAdapter.start_link(api_key: "sk-ant-api03-...")
  {:ok, capabilities} = ClaudeAdapter.capabilities(adapter)

  {:ok, session} = Session.new(%{agent_id: "my-agent"})
  {:ok, run} = Run.new(%{session_id: session.id, input: %{messages: [...]}})

  {:ok, result} = ClaudeAdapter.execute(adapter, run, session,
    event_callback: fn event -> IO.inspect(event) end
  )
  ```

  ## Configuration

  Optional:
  - `:model` - Model to use (default: "claude-haiku-4-5-20251001")
  - `:api_key` - Anthropic API key (optional; the SDK authenticates via
    `claude login` session or the `ANTHROPIC_API_KEY` environment variable)
  - `:sdk_module` - SDK module for testing (default: real SDK)
  - `:sdk_pid` - SDK process for testing
  """

  @behaviour AgentSessionManager.Ports.ProviderAdapter

  use GenServer

  alias AgentSessionManager.Core.{Capability, Error}
  alias AgentSessionManager.Ports.ProviderAdapter

  @default_model "claude-haiku-4-5-20251001"
  @emitted_events_key {__MODULE__, :emitted_events}

  defmodule RunState do
    @moduledoc false
    @enforce_keys [:run, :from, :task_ref, :task_pid]
    @type t :: %__MODULE__{
            run: map(),
            from: GenServer.from(),
            stream_ref: term(),
            cancelled: boolean(),
            task_ref: reference(),
            task_pid: pid()
          }
    defstruct [
      :run,
      :from,
      :stream_ref,
      :task_ref,
      :task_pid,
      cancelled: false
    ]
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the Claude adapter.

  ## Options

  - `:model` - Optional. The model to use (default: #{@default_model})
  - `:api_key` - Optional. Anthropic API key (SDK authenticates via `claude login` or env var).
  - `:permission_mode` - Optional. Normalized permission mode (see `AgentSessionManager.PermissionMode`).
  - `:sdk_module` - Optional. Mock SDK module for testing.
  - `:sdk_pid` - Optional. Mock SDK process for testing.
  - `:name` - Optional. GenServer name for registration.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
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
  def name(_adapter), do: "claude"

  @impl AgentSessionManager.Ports.ProviderAdapter
  def capabilities(adapter) when is_pid(adapter) do
    GenServer.call(adapter, :capabilities)
  end

  def capabilities(adapter) when is_atom(adapter) do
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
  def validate_config(_adapter, _config) do
    # ClaudeAgentSDK handles authentication internally via `claude login`
    # or the ANTHROPIC_API_KEY environment variable. No explicit config
    # validation is needed at the adapter level.
    :ok
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl GenServer
  def init(opts) do
    api_key = Keyword.get(opts, :api_key)
    model = Keyword.get(opts, :model, @default_model)
    sdk_module = Keyword.get(opts, :sdk_module)
    sdk_pid = Keyword.get(opts, :sdk_pid)
    tools = Keyword.get(opts, :tools)
    permission_mode = Keyword.get(opts, :permission_mode)
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    capabilities = build_capabilities()

    state = %{
      api_key: api_key,
      model: model,
      sdk_module: sdk_module,
      sdk_pid: sdk_pid,
      task_supervisor: task_supervisor,
      tools: tools,
      permission_mode: permission_mode,
      active_runs: %{},
      task_refs: %{},
      capabilities: capabilities
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:name, _from, state) do
    {:reply, "claude", state}
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
      stream_ref: nil,
      cancelled: false,
      task_pid: task.pid,
      task_ref: task.ref
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
        # Mark as cancelled
        new_run_state = %{run_state | cancelled: true}
        new_state = %{state | active_runs: Map.put(state.active_runs, run_id, new_run_state)}

        # Try to cancel the stream if we have a mock SDK
        if state.sdk_module && state.sdk_pid && run_state.stream_ref do
          state.sdk_module.cancel_stream(state.sdk_pid, run_state.stream_ref)
        end

        # Send cancellation notification to the worker process
        if run_state.task_pid do
          send(run_state.task_pid, {:cancelled_notification, run_id})
        end

        {:reply, {:ok, run_id}, new_state}
    end
  end

  @impl GenServer
  def handle_cast({:update_stream_ref, run_id, stream_ref}, state) do
    case Map.get(state.active_runs, run_id) do
      nil ->
        {:noreply, state}

      run_state ->
        new_run_state = %{run_state | stream_ref: stream_ref}
        new_state = put_in(state.active_runs[run_id], new_run_state)
        {:noreply, new_state}
    end
  end

  @impl GenServer
  def handle_info({:check_cancelled, run_id, reply_to}, state) do
    cancelled =
      case Map.get(state.active_runs, run_id) do
        nil -> false
        run_state -> run_state.cancelled
      end

    send(reply_to, {:cancelled_status, cancelled})
    {:noreply, state}
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

  defp do_execute(state, run, session, opts, adapter_pid) do
    event_callback = Keyword.get(opts, :event_callback)
    reset_emitted_events()
    prepared_input = prepare_input(run.input, session)

    # Build execution context
    ctx = %{
      run: run,
      session: session,
      prepared_input: prepared_input,
      event_callback: event_callback,
      adapter_pid: adapter_pid,
      accumulated_content: "",
      content_blocks: %{},
      tool_calls: [],
      token_usage: %{input_tokens: 0, output_tokens: 0},
      session_id: nil
    }

    # Determine which SDK interface to use
    cond do
      # New ClaudeAgentSDK-compatible interface (query/3 returning Message stream)
      state.sdk_module && function_exported?(state.sdk_module, :query, 3) ->
        execute_with_agent_sdk(state.sdk_module, state.sdk_pid, ctx, state)

      # Legacy mock SDK interface (subscribe/create_message)
      state.sdk_module && function_exported?(state.sdk_module, :subscribe, 2) ->
        execute_with_mock_sdk(state.sdk_module, state.sdk_pid, ctx, state)

      # Real ClaudeAgentSDK (not mocked)
      is_nil(state.sdk_module) ->
        execute_with_real_sdk(ctx, state)

      true ->
        {:error, Error.new(:internal_error, "Unknown SDK interface")}
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

  defp execute_with_real_sdk(ctx, state) do
    sdk_opts = build_sdk_options(state)
    prompt = extract_prompt(ctx.prepared_input)

    # Use ClaudeAgentSDK.Streaming for real token-level streaming deltas.
    # Query.run/3 delivers complete Message structs (no incremental output).
    try do
      case ClaudeAgentSDK.Streaming.start_session(sdk_opts) do
        {:ok, session} ->
          try do
            session_id =
              case ClaudeAgentSDK.Streaming.get_session_id(session) do
                {:ok, id} -> id
                _ -> nil
              end

            stream = ClaudeAgentSDK.Streaming.send_message(session, prompt)
            process_streaming_events(stream, %{ctx | session_id: session_id})
          after
            ClaudeAgentSDK.Streaming.close_session(session)
          end

        {:error, reason} ->
          error_message = "Failed to start streaming session: #{inspect(reason)}"

          emit_event(ctx, :error_occurred, %{
            error_code: :sdk_error,
            error_message: error_message
          })

          {:error, Error.new(:provider_error, error_message)}
      end
    rescue
      e ->
        error_message = Exception.message(e)

        emit_event(ctx, :error_occurred, %{
          error_code: :sdk_error,
          error_message: error_message
        })

        {:error, Error.new(:provider_error, error_message)}
    catch
      :exit, reason ->
        error_message = "SDK process exited: #{inspect(reason)}"

        emit_event(ctx, :error_occurred, %{
          error_code: :sdk_error,
          error_message: error_message
        })

        {:error, Error.new(:provider_error, error_message)}
    end
  end

  defp process_streaming_events(stream, ctx) do
    result =
      stream
      |> Enum.reduce_while(ctx, fn event, acc ->
        if cancelled?() do
          emit_event(acc, :run_cancelled, %{})
          {:halt, {:cancelled, acc}}
        else
          handle_streaming_event(event, acc)
        end
      end)

    case result do
      {:cancelled, _ctx} ->
        {:error, Error.new(:cancelled, "Run was cancelled")}

      {:error, error_msg} ->
        {:error, Error.new(:provider_error, error_msg)}

      final_ctx when is_map(final_ctx) ->
        build_claude_result(final_ctx)
    end
  end

  defp handle_streaming_event(%{type: :message_start} = event, ctx) do
    model = event[:model]

    # The parsed event's :usage is typically empty; fall back to the raw CLI event
    usage = event[:usage] || %{}
    raw_usage = get_in(event, [:raw_event, "message", "usage"]) || %{}
    input_tokens = usage[:input_tokens] || raw_usage["input_tokens"] || 0

    emit_event(ctx, :run_started, %{
      session_id: ctx.session_id,
      model: model
    })

    new_token_usage = %{ctx.token_usage | input_tokens: input_tokens}
    {:cont, %{ctx | token_usage: new_token_usage}}
  end

  defp handle_streaming_event(%{type: :text_delta, text: text}, ctx) do
    emit_event(ctx, :message_streamed, %{
      content: text,
      delta: text,
      session_id: ctx.session_id
    })

    {:cont, %{ctx | accumulated_content: ctx.accumulated_content <> text}}
  end

  defp handle_streaming_event(%{type: :tool_use_start} = event, ctx) do
    tool_input = normalize_tool_input(event[:input])

    emit_event(ctx, :tool_call_started, %{
      tool_call_id: event[:id],
      tool_use_id: event[:id],
      tool_name: event[:name],
      tool_input: tool_input
    })

    {:cont, ctx}
  end

  defp handle_streaming_event(%{type: :message_delta} = event, ctx) do
    stop_reason = event[:stop_reason]

    # The parsed event omits usage; fall back to the raw CLI event
    raw_usage = get_in(event, [:raw_event, "usage"]) || %{}
    output_tokens = raw_usage["output_tokens"] || ctx.token_usage.output_tokens

    new_token_usage = %{ctx.token_usage | output_tokens: output_tokens}
    {:cont, ctx |> Map.put(:stop_reason, stop_reason) |> Map.put(:token_usage, new_token_usage)}
  end

  defp handle_streaming_event(%{type: :message_stop}, ctx) do
    emit_event(ctx, :message_received, %{
      content: ctx.accumulated_content,
      role: "assistant"
    })

    emit_event(ctx, :token_usage_updated, %{
      input_tokens: ctx.token_usage.input_tokens,
      output_tokens: ctx.token_usage.output_tokens
    })

    emit_event(ctx, :run_completed, %{
      stop_reason: Map.get(ctx, :stop_reason, "end_turn"),
      session_id: ctx.session_id,
      token_usage: ctx.token_usage
    })

    {:halt, ctx}
  end

  defp handle_streaming_event(%{type: :error, error: reason}, ctx) do
    error_message = inspect(reason)

    emit_event(ctx, :error_occurred, %{
      error_code: :provider_error,
      error_message: error_message
    })

    {:halt, {:error, error_message}}
  end

  defp handle_streaming_event(_event, ctx) do
    {:cont, ctx}
  end

  defp execute_with_agent_sdk(sdk_module, sdk_pid, ctx, state) do
    # Use the ClaudeAgentSDK-compatible interface
    sdk_opts = build_sdk_options(state)
    stream = sdk_module.query(sdk_pid, ctx.prepared_input, sdk_opts)
    process_agent_sdk_stream(stream, ctx)
  end

  defp extract_prompt(input) when is_binary(input), do: input

  defp extract_prompt(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.map(&message_to_prompt_line/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp extract_prompt(input), do: inspect(input)

  defp message_to_prompt_line(message) when is_map(message) do
    role = Map.get(message, :role) || Map.get(message, "role")
    content = Map.get(message, :content) || Map.get(message, "content") || ""

    if is_binary(content) and content != "" do
      "#{role_to_string(role)}: #{content}"
    else
      ""
    end
  end

  defp message_to_prompt_line(_), do: ""

  defp prepare_input(input, session) do
    transcript_messages =
      session
      |> Map.get(:context, %{})
      |> Map.get(:transcript)
      |> transcript_to_input_messages()

    if transcript_messages == [] do
      input
    else
      current_messages = normalize_input_messages(input)

      %{
        messages: transcript_messages ++ current_messages
      }
    end
  end

  defp normalize_input_messages(%{messages: messages}) when is_list(messages), do: messages

  defp normalize_input_messages(input) when is_binary(input) do
    [%{role: "user", content: input}]
  end

  defp normalize_input_messages(input) do
    [%{role: "user", content: inspect(input)}]
  end

  defp transcript_to_input_messages(nil), do: []

  defp transcript_to_input_messages(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.map(&transcript_message_to_input/1)
    |> Enum.reject(&is_nil/1)
  end

  defp transcript_to_input_messages(_), do: []

  defp transcript_message_to_input(%{role: role, content: content})
       when is_binary(content) and content != "" do
    %{role: role_to_string(role), content: content}
  end

  defp transcript_message_to_input(%{
         role: :assistant,
         tool_name: tool_name,
         tool_call_id: tool_call_id,
         tool_input: tool_input
       })
       when is_binary(tool_name) do
    tool_id = if is_binary(tool_call_id), do: tool_call_id, else: "unknown"
    input = if is_map(tool_input), do: inspect(tool_input), else: "{}"
    %{role: "assistant", content: "tool_call(#{tool_id}): #{tool_name} #{input}"}
  end

  defp transcript_message_to_input(%{
         role: :tool,
         tool_name: tool_name,
         tool_call_id: tool_call_id,
         tool_output: tool_output
       })
       when is_binary(tool_name) do
    tool_id = if is_binary(tool_call_id), do: tool_call_id, else: "unknown"
    output = if is_nil(tool_output), do: "", else: inspect(tool_output)
    %{role: "tool", content: "tool_result(#{tool_id}): #{tool_name} #{output}"}
  end

  defp transcript_message_to_input(_), do: nil

  defp role_to_string(:system), do: "system"
  defp role_to_string(:user), do: "user"
  defp role_to_string(:assistant), do: "assistant"
  defp role_to_string(:tool), do: "tool"
  defp role_to_string(role) when is_binary(role), do: role
  defp role_to_string(_), do: "assistant"

  defp build_sdk_options(state) do
    # ClaudeAgentSDK handles auth via `claude login` session or ANTHROPIC_API_KEY env var.
    opts = %ClaudeAgentSDK.Options{
      model: state.model,
      max_turns: 1,
      setting_sources: ["user"],
      permission_mode: map_permission_mode(state.permission_mode)
    }

    if state.tools do
      %{opts | tools: state.tools}
    else
      opts
    end
  end

  defp map_permission_mode(:full_auto), do: :bypass_permissions
  defp map_permission_mode(:dangerously_skip_permissions), do: :bypass_permissions
  defp map_permission_mode(:accept_edits), do: :accept_edits
  defp map_permission_mode(:plan), do: :plan
  defp map_permission_mode(:default), do: nil
  defp map_permission_mode(nil), do: nil

  defp process_agent_sdk_stream(stream, ctx) do
    result =
      stream
      |> Enum.reduce_while(ctx, &process_sdk_message/2)
      |> handle_sdk_stream_result()

    result
  end

  defp process_sdk_message(message, ctx) do
    # Check for cancellation
    if cancelled?() do
      emit_event(ctx, :run_cancelled, %{})
      {:halt, {:cancelled, ctx}}
    else
      process_sdk_message_uncancelled(message, ctx)
    end
  end

  defp cancelled? do
    receive do
      {:cancelled_notification, _run_id} -> true
    after
      0 -> false
    end
  end

  defp process_sdk_message_uncancelled(%ClaudeAgentSDK.Message{} = message, ctx) do
    new_ctx = handle_sdk_message(message, ctx)

    case message do
      %{type: :result, subtype: :error_during_execution} ->
        {:halt, {:error, message, new_ctx}}

      %{type: :result, subtype: :error_max_turns} ->
        {:halt, {:error, message, new_ctx}}

      %{type: :result} ->
        {:halt, new_ctx}

      _ ->
        {:cont, new_ctx}
    end
  end

  defp handle_sdk_message(%ClaudeAgentSDK.Message{type: :system, subtype: :init} = msg, ctx) do
    session_id = msg.data[:session_id] || msg.data["session_id"]

    emit_event(ctx, :run_started, %{
      session_id: session_id,
      model: msg.data[:model],
      tools: msg.data[:tools] || []
    })

    %{ctx | session_id: session_id}
  end

  defp handle_sdk_message(%ClaudeAgentSDK.Message{type: :assistant} = msg, ctx) do
    content = extract_assistant_content(msg)
    tool_calls = extract_tool_calls(msg)

    # Emit message_streamed for each content chunk
    if content != "" do
      emit_event(ctx, :message_streamed, %{
        content: content,
        delta: content,
        session_id: ctx.session_id
      })
    end

    # Emit tool call events
    Enum.each(tool_calls, fn tool_call ->
      tool_input = normalize_tool_input(tool_call.input)

      emit_event(ctx, :tool_call_started, %{
        tool_call_id: tool_call.id,
        tool_use_id: tool_call.id,
        tool_name: tool_call.name,
        tool_input: tool_input,
        arguments: tool_call.input
      })

      emit_event(ctx, :tool_call_completed, %{
        tool_call_id: tool_call.id,
        tool_use_id: tool_call.id,
        tool_name: tool_call.name,
        tool_input: tool_input,
        input: tool_call.input
      })
    end)

    new_tool_calls =
      Enum.map(tool_calls, fn tc ->
        %{id: tc.id, name: tc.name, input: tc.input}
      end)

    %{
      ctx
      | accumulated_content: ctx.accumulated_content <> content,
        tool_calls: ctx.tool_calls ++ new_tool_calls
    }
  end

  defp handle_sdk_message(%ClaudeAgentSDK.Message{type: :result, subtype: :success} = msg, ctx) do
    # Usage may appear in data.usage, raw.usage, or at the raw top level
    usage = msg.data[:usage] || (msg.raw && msg.raw["usage"]) || %{}
    input_tokens = trunc(usage["input_tokens"] || usage[:input_tokens] || 0)
    output_tokens = trunc(usage["output_tokens"] || usage[:output_tokens] || 0)

    emit_event(ctx, :message_received, %{
      content: ctx.accumulated_content,
      role: "assistant"
    })

    emit_event(ctx, :token_usage_updated, %{
      input_tokens: input_tokens,
      output_tokens: output_tokens
    })

    emit_event(ctx, :run_completed, %{
      stop_reason: "end_turn",
      session_id: ctx.session_id,
      num_turns: msg.data[:num_turns],
      total_cost_usd: msg.data[:total_cost_usd],
      token_usage: %{input_tokens: input_tokens, output_tokens: output_tokens}
    })

    %{
      ctx
      | token_usage: %{input_tokens: input_tokens, output_tokens: output_tokens}
    }
  end

  defp handle_sdk_message(%ClaudeAgentSDK.Message{type: :result} = msg, ctx) do
    # Error result types
    error_message = msg.data[:error] || "Unknown error"

    emit_event(ctx, :error_occurred, %{
      error_code: :provider_error,
      error_message: error_message
    })

    emit_event(ctx, :run_failed, %{
      error_code: :provider_error,
      error_message: error_message
    })

    ctx
  end

  defp handle_sdk_message(_message, ctx) do
    # Unknown message type, ignore
    ctx
  end

  defp handle_sdk_stream_result({:error, _message, _ctx}) do
    error_message = "Execution failed"
    {:error, Error.new(:provider_error, error_message)}
  end

  defp handle_sdk_stream_result({:cancelled, ctx}) do
    emit_event(ctx, :run_cancelled, %{})
    {:error, Error.new(:cancelled, "Run was cancelled")}
  end

  defp handle_sdk_stream_result(ctx) do
    build_claude_result(ctx)
  end

  defp extract_assistant_content(%ClaudeAgentSDK.Message{data: %{message: message}}) do
    raw =
      case message do
        %{"content" => content} when is_list(content) ->
          content
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("", &(&1["text"] || ""))

        %{"content" => content} when is_binary(content) ->
          content

        _ ->
          ""
      end

    unescape_json_text(raw)
  end

  defp extract_assistant_content(_), do: ""

  # The SDK's fallback JSON parser may return text with literal escape sequences
  # (e.g. two-char "\n" instead of a real newline). Unescape common JSON sequences.
  # Order matters: escaped backslash (\\) must be sheltered first so that \\n
  # (literal backslash + n) isn't misread as a newline escape.
  defp unescape_json_text(text) do
    text
    |> String.replace("\\\\", "\x00")
    |> String.replace("\\n", "\n")
    |> String.replace("\\t", "\t")
    |> String.replace("\\\"", "\"")
    |> String.replace("\x00", "\\")
  end

  defp extract_tool_calls(%ClaudeAgentSDK.Message{data: %{message: message}}) do
    case message do
      %{"content" => content} when is_list(content) ->
        content
        |> Enum.filter(&(&1["type"] == "tool_use"))
        |> Enum.map(fn block ->
          %{
            id: block["id"],
            name: block["name"],
            input: block["input"] || %{}
          }
        end)

      _ ->
        []
    end
  end

  defp extract_tool_calls(_), do: []

  defp build_claude_result(ctx) do
    output = %{
      content: ctx.accumulated_content,
      stop_reason: "end_turn",
      tool_calls: ctx.tool_calls
    }

    {:ok,
     %{
       output: output,
       token_usage: ctx.token_usage,
       events: emitted_events()
     }}
  end

  defp execute_with_mock_sdk(sdk_module, sdk_pid, ctx, state) do
    # Subscribe to receive events
    :ok = sdk_module.subscribe(sdk_pid, self())

    # Create the message stream
    case sdk_module.create_message(sdk_pid, %{}) do
      {:ok, stream_ref} ->
        # Store the stream ref for potential cancellation
        GenServer.cast(ctx.adapter_pid, {:update_stream_ref, ctx.run.id, stream_ref})

        # Process the event stream
        process_event_stream(sdk_module, sdk_pid, ctx, state)

      {:error, error} ->
        # Emit error events
        emit_event(ctx, :error_occurred, %{
          error_code: error.code,
          error_message: error.message
        })

        emit_event(ctx, :run_failed, %{
          error_code: error.code,
          error_message: error.message
        })

        {:error, error}
    end
  end

  defp process_event_stream(sdk_module, sdk_pid, ctx, state) do
    # Initial run_started event is emitted when we receive message_start
    loop_result = receive_events(sdk_module, sdk_pid, ctx, state)

    case loop_result do
      {:ok, final_ctx} ->
        # Build final result
        result = build_result(final_ctx)
        {:ok, result}

      {:error, error, _final_ctx} ->
        # Error already emitted during processing
        {:error, error}

      {:cancelled, _final_ctx} ->
        {:error, Error.new(:cancelled, "Run was cancelled")}
    end
  end

  defp receive_events(sdk_module, sdk_pid, ctx, state) do
    # Check if cancelled by checking for a cancellation message first
    receive do
      {:cancelled_notification, _run_id} ->
        # Emit cancellation event
        emit_event(ctx, :run_cancelled, %{})
        {:cancelled, ctx}
    after
      0 ->
        # No cancellation pending, continue with events
        receive_claude_events(sdk_module, sdk_pid, ctx, state)
    end
  end

  defp receive_claude_events(sdk_module, sdk_pid, ctx, state) do
    receive do
      {:cancelled_notification, _run_id} ->
        # Received cancellation while waiting for events
        emit_event(ctx, :run_cancelled, %{})
        {:cancelled, ctx}

      {:claude_event, event} ->
        new_ctx = handle_claude_event(event, ctx)

        # Check if this is the final event
        if event.type == "message_stop" do
          {:ok, new_ctx}
        else
          receive_events(sdk_module, sdk_pid, new_ctx, state)
        end

      {:claude_error, error} ->
        emit_event(ctx, :error_occurred, %{
          error_code: error.code,
          error_message: error.message
        })

        emit_event(ctx, :run_failed, %{
          error_code: error.code,
          error_message: error.message
        })

        {:error, error, ctx}

      {:claude_cancelled, _stream_ref} ->
        emit_event(ctx, :run_cancelled, %{})
        {:cancelled, ctx}
    after
      30_000 ->
        error = Error.new(:provider_timeout, "Timeout waiting for events")

        emit_event(ctx, :error_occurred, %{
          error_code: :provider_timeout,
          error_message: "Timeout waiting for events"
        })

        emit_event(ctx, :run_failed, %{
          error_code: :provider_timeout,
          error_message: "Timeout waiting for events"
        })

        {:error, error, ctx}
    end
  end

  defp handle_claude_event(%{type: "message_start"} = event, ctx) do
    # Extract initial usage
    usage = get_in(event, [:message, :usage]) || %{}

    # Emit run_started
    emit_event(ctx, :run_started, %{
      message_id: get_in(event, [:message, :id]),
      model: get_in(event, [:message, :model])
    })

    %{ctx | token_usage: Map.merge(ctx.token_usage, atomize_usage(usage))}
  end

  defp handle_claude_event(%{type: "content_block_start"} = event, ctx) do
    index = event.index
    content_block = event.content_block

    case content_block.type do
      "text" ->
        # Track text content block
        new_blocks =
          Map.put(ctx.content_blocks, index, %{
            type: :text,
            content: ""
          })

        %{ctx | content_blocks: new_blocks}

      "tool_use" ->
        # Emit tool_call_started
        emit_event(ctx, :tool_call_started, %{
          tool_call_id: content_block.id,
          tool_use_id: content_block.id,
          tool_name: content_block.name,
          tool_input: %{},
          index: index
        })

        # Track tool use content block
        new_blocks =
          Map.put(ctx.content_blocks, index, %{
            type: :tool_use,
            id: content_block.id,
            name: content_block.name,
            input_json: ""
          })

        %{ctx | content_blocks: new_blocks}

      _ ->
        ctx
    end
  end

  defp handle_claude_event(%{type: "content_block_delta"} = event, ctx) do
    index = event.index
    delta = event.delta
    handle_delta(delta.type, delta, index, ctx)
  end

  defp handle_claude_event(%{type: "content_block_stop"} = event, ctx) do
    index = event.index
    block = Map.get(ctx.content_blocks, index)

    case block do
      %{type: :tool_use} = tool_block ->
        # Parse the accumulated JSON
        input =
          case Jason.decode(tool_block.input_json) do
            {:ok, parsed} -> parsed
            {:error, _} -> %{}
          end

        # Emit tool_call_completed
        emit_event(ctx, :tool_call_completed, %{
          tool_call_id: tool_block.id,
          tool_use_id: tool_block.id,
          tool_name: tool_block.name,
          tool_input: normalize_tool_input(input),
          input: input,
          index: index
        })

        # Add to tool calls list
        tool_call = %{
          id: tool_block.id,
          name: tool_block.name,
          input: input
        }

        %{ctx | tool_calls: ctx.tool_calls ++ [tool_call]}

      _ ->
        ctx
    end
  end

  defp handle_claude_event(%{type: "message_delta"} = event, ctx) do
    # Extract final usage and stop reason
    usage = event.usage || %{}
    stop_reason = get_in(event, [:delta, :stop_reason])

    # Emit token usage updated
    emit_event(ctx, :token_usage_updated, %{
      input_tokens: ctx.token_usage.input_tokens,
      output_tokens:
        usage[:output_tokens] || usage["output_tokens"] || ctx.token_usage.output_tokens
    })

    new_usage = %{
      ctx.token_usage
      | output_tokens:
          usage[:output_tokens] || usage["output_tokens"] || ctx.token_usage.output_tokens
    }

    Map.merge(ctx, %{token_usage: new_usage, stop_reason: stop_reason})
  end

  defp handle_claude_event(%{type: "message_stop"}, ctx) do
    # Emit message_received with full content
    emit_event(ctx, :message_received, %{
      content: ctx.accumulated_content,
      role: "assistant"
    })

    # Emit run_completed
    emit_event(ctx, :run_completed, %{
      stop_reason: Map.get(ctx, :stop_reason),
      token_usage: ctx.token_usage
    })

    ctx
  end

  defp handle_claude_event(%{type: "__disconnect__"} = event, ctx) do
    # Handle simulated disconnect
    error = event.error

    emit_event(ctx, :error_occurred, %{
      error_code: error.code,
      error_message: error.message
    })

    ctx
  end

  defp handle_claude_event(_event, ctx) do
    # Unknown event type, ignore
    ctx
  end

  defp handle_delta("text_delta", delta, index, ctx) do
    text = delta.text

    emit_event(ctx, :message_streamed, %{
      content: text,
      delta: text,
      index: index
    })

    new_content = ctx.accumulated_content <> text
    new_blocks = update_text_block(ctx.content_blocks, index, text)
    %{ctx | accumulated_content: new_content, content_blocks: new_blocks}
  end

  defp handle_delta("input_json_delta", delta, index, ctx) do
    partial_json = delta.partial_json
    new_blocks = update_json_block(ctx.content_blocks, index, partial_json)
    %{ctx | content_blocks: new_blocks}
  end

  defp handle_delta(_type, _delta, _index, ctx), do: ctx

  defp update_text_block(blocks, index, text) do
    case Map.get(blocks, index) do
      nil ->
        Map.put(blocks, index, %{type: :text, content: text})

      block ->
        Map.put(blocks, index, %{block | content: (block[:content] || "") <> text})
    end
  end

  defp update_json_block(blocks, index, partial_json) do
    case Map.get(blocks, index) do
      nil ->
        blocks

      block ->
        Map.put(blocks, index, %{block | input_json: (block[:input_json] || "") <> partial_json})
    end
  end

  defp emit_event(ctx, type, data) do
    event = %{
      type: type,
      timestamp: DateTime.utc_now(),
      session_id: ctx.session.id,
      run_id: ctx.run.id,
      data: data,
      provider: :claude
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
      stop_reason: Map.get(ctx, :stop_reason),
      tool_calls: ctx.tool_calls
    }

    %{
      output: output,
      token_usage: ctx.token_usage,
      events: emitted_events()
    }
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

  defp normalize_tool_input(input) when is_map(input), do: input
  defp normalize_tool_input(_), do: %{}

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
        name: "vision",
        type: :resource,
        enabled: true,
        description: "Image understanding capability"
      },
      %Capability{
        name: "system_prompts",
        type: :prompt,
        enabled: true,
        description: "System prompt support"
      },
      %Capability{
        name: "interrupt",
        type: :sampling,
        enabled: true,
        description: "Ability to interrupt/cancel in-progress requests"
      }
    ]
  end

  defp atomize_usage(usage) when is_map(usage) do
    %{
      input_tokens: usage[:input_tokens] || usage["input_tokens"] || 0,
      output_tokens: usage[:output_tokens] || usage["output_tokens"] || 0
    }
  end
end
