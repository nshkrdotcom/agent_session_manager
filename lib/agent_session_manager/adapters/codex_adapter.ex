if Code.ensure_loaded?(Codex) and Code.ensure_loaded?(Codex.Events) do
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
    | ItemStarted (tool items) | tool_call_started       | Command/file/MCP tool start        |
    | ItemCompleted (tool items)| tool_call_completed    | Command/file/MCP tool completion   |
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
    alias Codex.Items

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
    - `:permission_mode` - Optional. Normalized permission mode (see `AgentSessionManager.PermissionMode`).
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
          permission_mode = Keyword.get(opts, :permission_mode)
          max_turns = Keyword.get(opts, :max_turns)
          system_prompt = Keyword.get(opts, :system_prompt)
          sdk_opts = Keyword.get(opts, :sdk_opts, [])
          sdk_module = Keyword.get(opts, :sdk_module)
          sdk_pid = Keyword.get(opts, :sdk_pid)
          {:ok, task_supervisor} = Task.Supervisor.start_link()

          capabilities = build_capabilities()

          state = %{
            working_directory: working_directory,
            model: model,
            permission_mode: permission_mode,
            max_turns: max_turns,
            system_prompt: system_prompt,
            sdk_opts: sdk_opts,
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
        agent_messages: %{},
        agent_message_order: [],
        streamed_agent_message_ids: MapSet.new(),
        tool_calls: [],
        active_tools: %{},
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
           {:ok, streaming_result} <-
             Codex.Thread.run_streamed(thread, ctx.prompt, build_run_options(state)) do
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

    @doc false
    @spec build_thread_options_for_state(map()) ::
            {:ok, Codex.Thread.Options.t()} | {:error, term()}
    def build_thread_options_for_state(state) do
      build_thread_options(state)
    end

    @doc false
    @spec build_run_options_for_state(map()) :: map()
    def build_run_options_for_state(state) do
      build_run_options(state)
    end

    defp build_thread_options(state) do
      attrs =
        %{working_directory: state.working_directory}
        |> maybe_put(:base_instructions, state.system_prompt)

      with {:ok, thread_opts} <- Codex.Thread.Options.new(attrs) do
        # Apply sdk_opts first (lowest precedence)
        thread_opts = apply_sdk_opts(thread_opts, state.sdk_opts)
        # Then apply normalized options (highest precedence)
        {:ok, apply_permission_mode_struct(thread_opts, state.permission_mode)}
      end
    end

    defp build_run_options(state) do
      %{}
      |> maybe_put(:max_turns, state.max_turns)
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

    defp apply_sdk_opts(opts, []), do: opts

    defp apply_sdk_opts(opts, sdk_opts) do
      Enum.reduce(sdk_opts, opts, fn {key, value}, acc ->
        if Map.has_key?(acc, key), do: Map.put(acc, key, value), else: acc
      end)
    end

    defp apply_permission_mode_struct(opts, :full_auto) do
      %{opts | full_auto: true}
    end

    defp apply_permission_mode_struct(opts, :dangerously_skip_permissions) do
      %{opts | dangerously_bypass_approvals_and_sandbox: true}
    end

    defp apply_permission_mode_struct(opts, _mode), do: opts

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
      content = extract_message_content(item)
      item_id = extract_item_id(item)

      if content != "" do
        emit_event(ctx, :message_streamed, %{
          content: content,
          delta: content,
          thread_id: event.thread_id,
          turn_id: event.turn_id
        })
      end

      update_agent_message(ctx, item_id, content, :append)
    end

    defp handle_codex_event(%Events.ItemCompleted{item: item} = event, ctx) do
      case extract_completed_agent_message(item) do
        {:ok, item_id, text} ->
          already_streamed =
            is_binary(item_id) and MapSet.member?(ctx.streamed_agent_message_ids, item_id)

          if text != "" and not already_streamed do
            emit_event(ctx, :message_streamed, %{
              content: text,
              delta: text,
              thread_id: event.thread_id,
              turn_id: event.turn_id
            })
          end

          update_agent_message(ctx, item_id, text, :replace)

        :error ->
          case normalize_tool_item(item) do
            nil ->
              ctx

            %{id: tool_call_id, name: tool_name, input: tool_input, output: tool_output} ->
              emit_event(ctx, :tool_call_completed, %{
                tool_call_id: tool_call_id,
                tool_name: tool_name,
                tool_output: tool_output,
                thread_id: event.thread_id,
                turn_id: event.turn_id
              })

              tool_call = %{
                id: tool_call_id || "unknown",
                name: tool_name,
                input: tool_input,
                output: tool_output
              }

              %{
                ctx
                | tool_calls: ctx.tool_calls ++ [tool_call],
                  active_tools: drop_active_tool(ctx.active_tools, tool_call_id)
              }
          end
      end
    end

    defp handle_codex_event(%Events.ItemStarted{item: item} = event, ctx) do
      case normalize_tool_item(item) do
        nil ->
          ctx

        %{id: tool_call_id, name: tool_name, input: tool_input} ->
          emit_event(ctx, :tool_call_started, %{
            tool_call_id: tool_call_id,
            tool_name: tool_name,
            tool_input: tool_input,
            thread_id: event.thread_id,
            turn_id: event.turn_id
          })

          %{
            ctx
            | active_tools: put_active_tool(ctx.active_tools, tool_call_id, tool_name, tool_input)
          }
      end
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
      tool_input = normalize_tool_input(event.arguments)

      emit_event(ctx, :tool_call_started, %{
        tool_call_id: event.call_id,
        tool_name: event.tool_name,
        tool_input: tool_input,
        thread_id: event.thread_id,
        turn_id: event.turn_id
      })

      %{
        ctx
        | active_tools:
            put_active_tool(ctx.active_tools, event.call_id, event.tool_name, tool_input)
      }
    end

    defp handle_codex_event(%Events.ToolCallCompleted{} = event, ctx) do
      active_tool = Map.get(ctx.active_tools, event.call_id)
      tool_input = if is_map(active_tool), do: Map.get(active_tool, :input, %{}), else: %{}

      emit_event(ctx, :tool_call_completed, %{
        tool_call_id: event.call_id,
        tool_name: event.tool_name,
        tool_output: event.output,
        thread_id: event.thread_id,
        turn_id: event.turn_id
      })

      tool_call = %{
        id: event.call_id,
        name: event.tool_name,
        input: tool_input,
        output: event.output
      }

      %{
        ctx
        | tool_calls: ctx.tool_calls ++ [tool_call],
          active_tools: drop_active_tool(ctx.active_tools, event.call_id)
      }
    end

    defp handle_codex_event(%Events.TurnCompleted{} = event, ctx) do
      final_content = final_agent_content(ctx)

      # Emit message_received with accumulated content
      emit_event(ctx, :message_received, %{
        content: final_content,
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

      %{final_ctx | accumulated_content: final_content}
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

    defp extract_item_id(%{id: id}) when is_binary(id), do: id
    defp extract_item_id(%{"id" => id}) when is_binary(id), do: id
    defp extract_item_id(%{item_id: id}) when is_binary(id), do: id
    defp extract_item_id(%{"item_id" => id}) when is_binary(id), do: id
    defp extract_item_id(_), do: nil

    defp extract_completed_agent_message(%Items.AgentMessage{text: text} = item)
         when is_binary(text) do
      {:ok, extract_item_id(item), text}
    end

    defp extract_completed_agent_message(%{} = item) do
      item_type = Map.get(item, :type) || Map.get(item, "type")

      if item_type in [:agent_message, "agent_message", "agentMessage"] do
        text = extract_message_content(item)

        if text != "" do
          {:ok, extract_item_id(item), text}
        else
          :error
        end
      else
        :error
      end
    end

    defp extract_completed_agent_message(_), do: :error

    defp update_agent_message(ctx, _item_id, "", _mode), do: ctx

    defp update_agent_message(ctx, item_id, content, mode) do
      normalized_id = item_id || "__anonymous__"

      previous = Map.get(ctx.agent_messages, normalized_id, "")

      next_content =
        case mode do
          :replace -> content
          _ -> previous <> content
        end

      order =
        if normalized_id in ctx.agent_message_order do
          ctx.agent_message_order
        else
          ctx.agent_message_order ++ [normalized_id]
        end

      streamed_ids =
        if is_binary(item_id) do
          MapSet.put(ctx.streamed_agent_message_ids, item_id)
        else
          ctx.streamed_agent_message_ids
        end

      %{
        ctx
        | agent_messages: Map.put(ctx.agent_messages, normalized_id, next_content),
          agent_message_order: order,
          streamed_agent_message_ids: streamed_ids,
          accumulated_content: next_content
      }
    end

    defp final_agent_content(ctx) do
      case List.last(ctx.agent_message_order) do
        nil -> ctx.accumulated_content
        id -> Map.get(ctx.agent_messages, id, ctx.accumulated_content)
      end
    end

    defp put_active_tool(active_tools, nil, _tool_name, _tool_input), do: active_tools

    defp put_active_tool(active_tools, tool_call_id, tool_name, tool_input) do
      Map.put(active_tools, tool_call_id, %{name: tool_name, input: tool_input})
    end

    defp drop_active_tool(active_tools, nil), do: active_tools
    defp drop_active_tool(active_tools, tool_call_id), do: Map.delete(active_tools, tool_call_id)

    defp normalize_tool_item(%Items.CommandExecution{} = item) do
      %{
        id: extract_item_id(item),
        name: "bash",
        input: normalize_tool_input(%{command: item.command, cwd: item.cwd}),
        output:
          normalize_tool_output(%{
            output: item.aggregated_output,
            exit_code: item.exit_code,
            status: item.status,
            duration_ms: item.duration_ms
          })
      }
    end

    defp normalize_tool_item(%Items.FileChange{} = item) do
      %{
        id: extract_item_id(item),
        name: "apply_patch",
        input: normalize_tool_input(%{changes: item.changes}),
        output: normalize_tool_output(%{status: item.status, changes: item.changes})
      }
    end

    defp normalize_tool_item(%Items.McpToolCall{} = item) do
      tool_name =
        case {item.server, item.tool} do
          {server, tool} when is_binary(server) and is_binary(tool) -> "#{server}:#{tool}"
          {_server, tool} when is_binary(tool) -> tool
          _ -> "mcp_tool"
        end

      output =
        cond do
          item.status == :failed and not is_nil(item.error) -> item.error
          not is_nil(item.result) -> item.result
          true -> %{}
        end

      %{
        id: extract_item_id(item),
        name: tool_name,
        input: normalize_tool_input(item.arguments),
        output: normalize_tool_output(output)
      }
    end

    defp normalize_tool_item(%{} = item) do
      type = Map.get(item, :type) || Map.get(item, "type")

      case normalize_item_type(type) do
        "command_execution" ->
          normalize_command_item_from_map(item)

        "file_change" ->
          normalize_file_change_item_from_map(item)

        "mcp_tool_call" ->
          normalize_mcp_tool_item_from_map(item)

        _ ->
          normalize_generic_tool_item_from_map(item)
      end
    end

    defp normalize_tool_item(_), do: nil

    defp normalize_command_item_from_map(item) do
      normalize_tool_item_from_map(item, "bash", [:command, "command"], fn map ->
        %{
          output: Map.get(map, :aggregated_output) || Map.get(map, "aggregated_output"),
          exit_code: Map.get(map, :exit_code) || Map.get(map, "exit_code"),
          status: Map.get(map, :status) || Map.get(map, "status"),
          duration_ms: Map.get(map, :duration_ms) || Map.get(map, "duration_ms")
        }
      end)
    end

    defp normalize_file_change_item_from_map(item) do
      changes = Map.get(item, :changes) || Map.get(item, "changes")

      %{
        id: extract_item_id(item),
        name: "apply_patch",
        input: normalize_tool_input(%{changes: changes}),
        output:
          normalize_tool_output(%{
            status: Map.get(item, :status) || Map.get(item, "status"),
            changes: changes
          })
      }
    end

    defp normalize_tool_item_from_map(item, tool_name, command_keys, output_builder) do
      command = Enum.find_value(command_keys, fn key -> Map.get(item, key) end)

      %{
        id: extract_item_id(item),
        name: tool_name,
        input:
          normalize_tool_input(%{
            command: command,
            cwd: Map.get(item, :cwd) || Map.get(item, "cwd")
          }),
        output: normalize_tool_output(output_builder.(item))
      }
    end

    defp normalize_mcp_tool_item_from_map(item) do
      server = get_flex(item, :server)
      tool = get_flex(item, :tool)

      tool_name =
        case {server, tool} do
          {srv, tl} when is_binary(srv) and is_binary(tl) -> "#{srv}:#{tl}"
          {_srv, tl} when is_binary(tl) -> tl
          _ -> "mcp_tool"
        end

      output = mcp_tool_output(item)

      %{
        id: extract_item_id(item),
        name: tool_name,
        input: normalize_tool_input(get_flex(item, :arguments)),
        output: normalize_tool_output(output)
      }
    end

    defp mcp_tool_output(item) do
      status = get_flex(item, :status)
      error = get_flex(item, :error)
      result = get_flex(item, :result)

      cond do
        status == :failed and not is_nil(error) -> error
        not is_nil(result) -> result
        true -> %{}
      end
    end

    defp get_flex(map, key) when is_atom(key) do
      Map.get(map, key) || Map.get(map, Atom.to_string(key))
    end

    defp normalize_generic_tool_item_from_map(item) do
      item_type = normalize_item_type(Map.get(item, :type) || Map.get(item, "type"))

      if item_type in [
           nil,
           "agent_message",
           "reasoning",
           "user_message",
           "image_view",
           "review_mode",
           "todo_list",
           "error",
           "ghost_snapshot",
           "compaction"
         ] do
        nil
      else
        output =
          %{
            output: Map.get(item, :output) || Map.get(item, "output"),
            result: Map.get(item, :result) || Map.get(item, "result"),
            error: Map.get(item, :error) || Map.get(item, "error"),
            status: Map.get(item, :status) || Map.get(item, "status")
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        input =
          item
          |> normalize_value()
          |> Map.drop([
            :__struct__,
            "__struct__",
            :id,
            "id",
            :item_id,
            "item_id",
            :type,
            "type",
            :output,
            "output",
            :result,
            "result",
            :error,
            "error",
            :status,
            "status"
          ])

        %{
          id: extract_item_id(item),
          name: item_type,
          input: normalize_tool_input(input),
          output: normalize_tool_output(output)
        }
      end
    end

    defp normalize_item_type(nil), do: nil

    defp normalize_item_type(type) when is_atom(type),
      do: normalize_item_type(Atom.to_string(type))

    defp normalize_item_type(type) when is_binary(type) do
      type
      |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1_\\2")
      |> String.downcase()
    end

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
      final_content = final_agent_content(ctx)

      output = %{
        content: final_content,
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

    defp normalize_tool_input(arguments) when is_map(arguments), do: normalize_value(arguments)
    defp normalize_tool_input(_), do: %{}

    defp normalize_tool_output(output) when is_map(output), do: normalize_value(output)
    defp normalize_tool_output(output) when is_list(output), do: %{items: normalize_value(output)}
    defp normalize_tool_output(nil), do: %{}
    defp normalize_tool_output(output), do: %{value: normalize_value(output)}

    # Normalizes structs/maps/lists into plain JSON-safe terms so event payloads
    # never depend on `Enumerable` implementations for provider structs.
    defp normalize_value(%{__struct__: _} = struct) do
      struct
      |> Map.from_struct()
      |> normalize_value()
    end

    defp normalize_value(map) when is_map(map) do
      Map.new(map, fn {key, value} -> {key, normalize_value(value)} end)
    end

    defp normalize_value(list) when is_list(list) do
      Enum.map(list, &normalize_value/1)
    end

    defp normalize_value(value), do: value

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
else
  defmodule AgentSessionManager.Adapters.CodexAdapter do
    @moduledoc """
    Fallback implementation used when optional Codex SDK dependencies are not installed.
    """

    @behaviour AgentSessionManager.Ports.ProviderAdapter

    alias AgentSessionManager.OptionalDependency
    alias AgentSessionManager.Ports.ProviderAdapter

    @impl ProviderAdapter
    def name(_adapter), do: "codex"

    @impl ProviderAdapter
    def capabilities(_adapter), do: {:error, missing_dependency_error(:capabilities)}

    @impl ProviderAdapter
    def execute(_adapter, _run, _session, _opts \\ []),
      do: {:error, missing_dependency_error(:execute)}

    @impl ProviderAdapter
    def cancel(_adapter, _run_id), do: {:error, missing_dependency_error(:cancel)}

    @impl ProviderAdapter
    def validate_config(_adapter, _config),
      do: {:error, missing_dependency_error(:validate_config)}

    @spec start_link(keyword()) :: {:error, AgentSessionManager.Core.Error.t()}
    def start_link(_opts \\ []), do: {:error, missing_dependency_error(:start_link)}

    @spec stop(GenServer.server()) :: :ok
    def stop(_server), do: :ok

    defp missing_dependency_error(operation) do
      OptionalDependency.error(:codex_sdk, __MODULE__, operation)
    end
  end
end
