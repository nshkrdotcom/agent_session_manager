defmodule AgentSessionManager.Adapters.CodexAdapter do
  @moduledoc """
  Provider adapter for Codex (Claude Code CLI) integration.

  This adapter implements the `ProviderAdapter` behaviour and provides:

  - Streaming execution via Codex SDK's Thread.run_streamed/3
  - Tool use support with proper event mapping
  - Interrupt/cancel capability
  - Accurate capability advertisement

  ## Event Mapping

  Codex SDK events are mapped to normalized events as follows:

  | Codex Event              | Normalized Event        | Notes                              |
  |--------------------------|-------------------------|------------------------------------|
  | ThreadStarted            | run_started             | Signals execution has begun        |
  | ItemAgentMessageDelta    | message_streamed        | Each delta emits a stream event    |
  | ThreadTokenUsageUpdated  | token_usage_updated     | Usage statistics                   |
  | ToolCallRequested        | tool_call_started       | Tool invocation requested          |
  | ToolCallCompleted        | tool_call_completed     | Tool finished with output          |
  | TurnCompleted            | message_received,       | Emits full message then completion |
  |                          | run_completed           |                                    |
  | Error / TurnFailed       | error_occurred,         | Error handling                     |
  |                          | run_failed              |                                    |

  ## Usage

  ```elixir
  {:ok, adapter} = CodexAdapter.start_link(working_directory: "/path/to/project")
  {:ok, capabilities} = CodexAdapter.capabilities(adapter)

  {:ok, session} = Session.new(%{agent_id: "my-agent"})
  {:ok, run} = Run.new(%{session_id: session.id, input: "Hello"})

  {:ok, result} = CodexAdapter.execute(adapter, run, session,
    event_callback: fn event -> IO.inspect(event) end
  )
  ```

  ## Configuration

  Required:
  - `:working_directory` - Working directory for Codex operations

  Optional:
  - `:model` - Model to use (default: determined by Codex)
  - `:sdk_module` - SDK module for testing (default: real Codex SDK)
  - `:sdk_pid` - SDK process for testing
  """

  @behaviour AgentSessionManager.Ports.ProviderAdapter

  use GenServer

  alias AgentSessionManager.Core.{Capability, Error}
  alias AgentSessionManager.Ports.ProviderAdapter
  alias Codex.Events

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
            streaming_result: term()
          }
    defstruct [
      :run,
      :from,
      :task_ref,
      :task_pid,
      cancelled: false,
      streaming_result: nil
    ]
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the Codex adapter.

  ## Options

  - `:working_directory` - Required. The working directory for Codex operations.
  - `:model` - Optional. The model to use.
  - `:sdk_module` - Optional. Mock SDK module for testing.
  - `:sdk_pid` - Optional. Mock SDK process for testing.
  - `:name` - Optional. GenServer name for registration.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    with {:ok, _working_directory} <- extract_working_directory(opts) do
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
  def name(_adapter), do: "codex"

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
      not Map.has_key?(config, :working_directory) ->
        {:error, Error.new(:validation_error, "working_directory is required")}

      config.working_directory == "" ->
        {:error, Error.new(:validation_error, "working_directory cannot be empty")}

      true ->
        :ok
    end
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl GenServer
  def init(opts) do
    case extract_working_directory(opts) do
      {:ok, working_directory} ->
        model = Keyword.get(opts, :model)
        sdk_module = Keyword.get(opts, :sdk_module)
        sdk_pid = Keyword.get(opts, :sdk_pid)
        {:ok, task_supervisor} = Task.Supervisor.start_link()

        capabilities = build_capabilities()

        state = %{
          working_directory: working_directory,
          model: model,
          sdk_module: sdk_module,
          sdk_pid: sdk_pid,
          task_supervisor: task_supervisor,
          active_runs: %{},
          task_refs: %{},
          capabilities: capabilities
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_call(:name, _from, state) do
    {:reply, "codex", state}
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
      streaming_result: nil
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

        new_state = %{
          state
          | active_runs: Map.put(state.active_runs, run_id, new_run_state)
        }

        # Try to cancel via mock SDK if available
        if state.sdk_module && state.sdk_pid do
          state.sdk_module.cancel(state.sdk_pid)
        end

        # Try to cancel via real SDK streaming result if available
        if run_state.streaming_result do
          Codex.RunResultStreaming.cancel(run_state.streaming_result, :immediate)
        end

        # Send cancellation notification to the worker process
        if run_state.task_pid do
          send(run_state.task_pid, {:cancelled_notification, run_id})
        end

        {:reply, {:ok, run_id}, new_state}
    end
  end

  @impl GenServer
  def handle_cast({:update_streaming_result, run_id, streaming_result}, state) do
    case Map.get(state.active_runs, run_id) do
      nil ->
        {:noreply, state}

      run_state ->
        new_run_state = %{run_state | streaming_result: streaming_result}
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

  defp extract_working_directory(opts) do
    case Keyword.fetch(opts, :working_directory) do
      {:ok, working_directory} when is_binary(working_directory) and working_directory != "" ->
        {:ok, working_directory}

      {:ok, ""} ->
        {:error, Error.new(:validation_error, "working_directory cannot be empty")}

      {:ok, _} ->
        {:error, Error.new(:validation_error, "working_directory must be a non-empty string")}

      :error ->
        {:error, Error.new(:validation_error, "working_directory is required")}
    end
  end

  defp do_execute(state, run, session, opts, adapter_pid) do
    event_callback = Keyword.get(opts, :event_callback)
    reset_emitted_events()
    prompt = build_prompt(run.input, session)

    # Build execution context
    ctx = %{
      run: run,
      session: session,
      prompt: prompt,
      event_callback: event_callback,
      adapter_pid: adapter_pid,
      model: state.model,
      accumulated_content: "",
      tool_calls: [],
      token_usage: %{input_tokens: 0, output_tokens: 0},
      thread_id: nil
    }

    # Use mock SDK if configured, otherwise use real Codex SDK
    case state.sdk_module do
      nil ->
        execute_with_real_sdk(state, ctx)

      sdk_module ->
        execute_with_mock_sdk(sdk_module, state.sdk_pid, ctx, state)
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

  defp execute_with_real_sdk(state, ctx) do
    # Build Codex SDK options using proper struct constructors
    with {:ok, codex_opts} <- build_codex_options(state),
         {:ok, thread_opts} <- build_thread_options(state),
         {:ok, thread} <- Codex.start_thread(codex_opts, thread_opts),
         {:ok, streaming_result} <- Codex.Thread.run_streamed(thread, ctx.prompt, %{}) do
      # Notify the adapter about the streaming result for cancellation tracking
      GenServer.cast(ctx.adapter_pid, {:update_streaming_result, ctx.run.id, streaming_result})

      # Get the raw events stream and process it
      events_stream = Codex.RunResultStreaming.raw_events(streaming_result)

      # Store the streaming result for potential cancellation
      ctx_with_stream = Map.put(ctx, :streaming_result, streaming_result)

      process_real_event_stream(events_stream, ctx_with_stream, thread)
    else
      {:error, reason} ->
        error_message = format_codex_error(reason)

        emit_event(ctx, :error_occurred, %{
          error_code: :sdk_error,
          error_message: error_message
        })

        {:error, Error.new(:provider_error, error_message)}
    end
  end

  defp build_codex_options(state) do
    attrs = %{}
    attrs = if state.model, do: Map.put(attrs, :model, state.model), else: attrs
    Codex.Options.new(attrs)
  end

  defp build_thread_options(state) do
    Codex.Thread.Options.new(%{working_directory: state.working_directory})
  end

  defp extract_prompt(input) when is_binary(input), do: input

  defp extract_prompt(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.filter(fn msg -> msg[:role] == "user" || msg["role"] == "user" end)
    |> Enum.map_join("\n", fn msg -> msg[:content] || msg["content"] || "" end)
  end

  defp extract_prompt(input), do: inspect(input)

  defp build_prompt(input, session) do
    transcript_prompt =
      session
      |> Map.get(:context, %{})
      |> Map.get(:transcript)
      |> transcript_to_prompt()

    current_prompt = extract_prompt(input)

    cond do
      transcript_prompt == "" -> current_prompt
      current_prompt == "" -> transcript_prompt
      true -> transcript_prompt <> "\n\n" <> current_prompt
    end
  end

  defp transcript_to_prompt(nil), do: ""

  defp transcript_to_prompt(%{messages: messages}) when is_list(messages) do
    messages
    |> Enum.map(&format_transcript_message/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp transcript_to_prompt(_), do: ""

  defp format_transcript_message(%{role: role, content: content}) when is_binary(content) do
    "#{role_label(role)}: #{content}"
  end

  defp format_transcript_message(%{
         role: :assistant,
         tool_name: tool_name,
         tool_call_id: tool_call_id,
         tool_input: tool_input
       })
       when is_binary(tool_name) do
    tool_id = if is_binary(tool_call_id), do: tool_call_id, else: "unknown"
    input = if is_map(tool_input), do: inspect(tool_input), else: "{}"
    "assistant_tool_call(#{tool_id}): #{tool_name} #{input}"
  end

  defp format_transcript_message(%{
         role: :tool,
         tool_name: tool_name,
         tool_call_id: tool_call_id,
         tool_output: tool_output
       })
       when is_binary(tool_name) do
    tool_id = if is_binary(tool_call_id), do: tool_call_id, else: "unknown"
    output = if is_nil(tool_output), do: "", else: inspect(tool_output)
    "tool_result(#{tool_id}): #{tool_name} #{output}"
  end

  defp format_transcript_message(_), do: ""

  defp role_label(:system), do: "system"
  defp role_label(:user), do: "user"
  defp role_label(:assistant), do: "assistant"
  defp role_label(:tool), do: "tool"
  defp role_label(role) when is_binary(role), do: role
  defp role_label(_), do: "assistant"

  defp process_real_event_stream(events_stream, ctx, thread) do
    # Update context with thread_id once available
    ctx = Map.put(ctx, :thread_id, thread.thread_id)

    events_stream
    |> Enum.reduce_while(ctx, &process_single_event/2)
    |> handle_stream_result()
  end

  defp format_codex_error({:exec_failed, error}) when is_struct(error) do
    Map.get(error, :message, inspect(error))
  end

  defp format_codex_error({:exec_failed, reason}) do
    inspect(reason)
  end

  defp format_codex_error(%{message: message}) when is_binary(message) do
    message
  end

  defp format_codex_error(reason) when is_binary(reason) do
    reason
  end

  defp format_codex_error(reason) do
    inspect(reason)
  end

  defp execute_with_mock_sdk(sdk_module, sdk_pid, ctx, _state) do
    case sdk_module.run_streamed(sdk_pid, nil, ctx.prompt, []) do
      {:ok, result} ->
        process_event_stream(sdk_module, result, ctx)

      {:error, error} ->
        emit_event(ctx, :error_occurred, %{
          error_code: :sdk_error,
          error_message: inspect(error)
        })

        {:error, Error.new(:provider_error, inspect(error))}
    end
  end

  defp process_event_stream(sdk_module, result, ctx) do
    events_stream = sdk_module.raw_events(result)

    events_stream
    |> Enum.reduce_while(ctx, &process_single_event/2)
    |> handle_stream_result()
  end

  defp process_single_event(event, acc_ctx) do
    if cancelled?() do
      emit_event(acc_ctx, :run_cancelled, %{})
      {:halt, {:cancelled, acc_ctx}}
    else
      process_event_uncancelled(event, acc_ctx)
    end
  end

  defp cancelled? do
    receive do
      {:cancelled_notification, _run_id} -> true
    after
      0 -> false
    end
  end

  defp process_event_uncancelled(event, acc_ctx) do
    new_ctx = handle_codex_event(event, acc_ctx)

    case classify_event(event) do
      :error -> {:halt, {:error, event, new_ctx}}
      :cancelled -> {:halt, {:cancelled, new_ctx}}
      :continue -> {:cont, new_ctx}
    end
  end

  defp classify_event(%Events.TurnFailed{}), do: :error
  defp classify_event(%Events.Error{}), do: :error
  defp classify_event(%Events.TurnAborted{}), do: :cancelled
  defp classify_event(_), do: :continue

  defp handle_stream_result({:error, error_event, error_ctx}) do
    error_message = extract_error_message(error_event)

    emit_event(error_ctx, :error_occurred, %{
      error_code: :provider_error,
      error_message: error_message
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

  defp extract_error_message(%Events.TurnFailed{error: error}),
    do: error["message"] || "Turn failed"

  defp extract_error_message(%Events.Error{message: msg}),
    do: msg || "Unknown error"

  defp extract_error_message(_), do: "Unknown error"

  defp handle_codex_event(%Events.ThreadStarted{} = event, ctx) do
    emit_event(ctx, :run_started, %{
      thread_id: event.thread_id,
      model: ctx[:model],
      metadata: event.metadata
    })

    %{ctx | thread_id: event.thread_id}
  end

  defp handle_codex_event(%Events.TurnStarted{}, ctx) do
    # Internal event, no normalized mapping needed
    ctx
  end

  defp handle_codex_event(%Events.ItemAgentMessageDelta{item: item} = event, ctx) do
    # Extract delta content from the item
    content = extract_message_content(item)

    if content != "" do
      emit_event(ctx, :message_streamed, %{
        content: content,
        delta: content,
        thread_id: event.thread_id,
        turn_id: event.turn_id
      })
    end

    %{ctx | accumulated_content: ctx.accumulated_content <> content}
  end

  defp handle_codex_event(
         %Events.ItemCompleted{item: %Codex.Items.AgentMessage{text: text}} = event,
         ctx
       )
       when is_binary(text) do
    # ItemCompleted with AgentMessage carries the full response text.
    # Only emit as streamed if we haven't already accumulated this content via deltas.
    already_have = ctx.accumulated_content

    if already_have == "" and text != "" do
      emit_event(ctx, :message_streamed, %{
        content: text,
        delta: text,
        thread_id: event.thread_id,
        turn_id: event.turn_id
      })

      %{ctx | accumulated_content: text}
    else
      ctx
    end
  end

  defp handle_codex_event(%Events.ItemCompleted{}, ctx) do
    # Non-AgentMessage item completed, ignore
    ctx
  end

  defp handle_codex_event(%Events.ItemStarted{}, ctx) do
    # Item started, no action needed
    ctx
  end

  defp handle_codex_event(%Events.ItemUpdated{}, ctx) do
    # Item updated, no action needed
    ctx
  end

  defp handle_codex_event(%Events.ThreadTokenUsageUpdated{usage: usage} = event, ctx) do
    input_tokens = usage["input_tokens"] || usage[:input_tokens] || 0
    output_tokens = usage["output_tokens"] || usage[:output_tokens] || 0

    emit_event(ctx, :token_usage_updated, %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      thread_id: event.thread_id,
      turn_id: event.turn_id
    })

    %{
      ctx
      | token_usage: %{
          input_tokens: input_tokens,
          output_tokens: output_tokens
        }
    }
  end

  defp handle_codex_event(%Events.ToolCallRequested{} = event, ctx) do
    emit_event(ctx, :tool_call_started, %{
      call_id: event.call_id,
      tool_name: event.tool_name,
      arguments: event.arguments,
      thread_id: event.thread_id,
      turn_id: event.turn_id
    })

    ctx
  end

  defp handle_codex_event(%Events.ToolCallCompleted{} = event, ctx) do
    emit_event(ctx, :tool_call_completed, %{
      call_id: event.call_id,
      tool_name: event.tool_name,
      output: event.output,
      thread_id: event.thread_id,
      turn_id: event.turn_id
    })

    tool_call = %{
      id: event.call_id,
      name: event.tool_name,
      input: %{},
      output: event.output
    }

    %{ctx | tool_calls: ctx.tool_calls ++ [tool_call]}
  end

  defp handle_codex_event(%Events.TurnCompleted{} = event, ctx) do
    # Emit message_received with accumulated content
    emit_event(ctx, :message_received, %{
      content: ctx.accumulated_content,
      role: "assistant",
      thread_id: event.thread_id,
      turn_id: event.turn_id
    })

    # Update final token usage if provided
    final_ctx =
      if event.usage do
        input_tokens = event.usage["input_tokens"] || event.usage[:input_tokens] || 0
        output_tokens = event.usage["output_tokens"] || event.usage[:output_tokens] || 0

        %{
          ctx
          | token_usage: %{
              input_tokens: input_tokens,
              output_tokens: output_tokens
            }
        }
      else
        ctx
      end

    # Emit run_completed
    emit_event(final_ctx, :run_completed, %{
      stop_reason: event.status || "end_turn",
      status: event.status,
      thread_id: event.thread_id,
      turn_id: event.turn_id,
      token_usage: final_ctx.token_usage
    })

    final_ctx
  end

  defp handle_codex_event(%Events.TurnAborted{}, ctx) do
    # Will be handled by the reduce_while halt
    ctx
  end

  defp handle_codex_event(%Events.Error{}, ctx) do
    # Will be handled by the reduce_while halt
    ctx
  end

  defp handle_codex_event(%Events.TurnFailed{}, ctx) do
    # Will be handled by the reduce_while halt
    ctx
  end

  defp handle_codex_event(_event, ctx) do
    # Unknown event type, ignore
    ctx
  end

  # Codex ItemAgentMessageDelta items use "text" directly (string-keyed map)
  defp extract_message_content(%{"text" => text}) when is_binary(text), do: text

  # Codex Items.AgentMessage struct (atom-keyed)
  defp extract_message_content(%{text: text}) when is_binary(text), do: text

  # Nested content block with text type
  defp extract_message_content(%{"content" => %{"type" => "text", "text" => text}})
       when is_binary(text),
       do: text

  # Content block arrays
  defp extract_message_content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("", &(&1["text"] || ""))
  end

  defp extract_message_content(%{"content" => content}) when is_binary(content) do
    content
  end

  defp extract_message_content(_), do: ""

  defp emit_event(ctx, type, data) do
    event = %{
      type: type,
      timestamp: DateTime.utc_now(),
      session_id: ctx.session.id,
      run_id: ctx.run.id,
      data: data,
      provider: :codex
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
