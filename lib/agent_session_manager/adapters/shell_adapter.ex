defmodule AgentSessionManager.Adapters.ShellAdapter do
  @moduledoc """
  Provider adapter for shell command execution.

  Implements the `ProviderAdapter` behaviour, enabling shell commands
  to participate in the full SessionManager lifecycle.
  """

  @behaviour AgentSessionManager.Ports.ProviderAdapter

  use GenServer

  alias AgentSessionManager.Core.{Capability, Error}
  alias AgentSessionManager.Ports.ProviderAdapter
  alias AgentSessionManager.Workspace.Exec

  @default_timeout_ms 30_000
  @default_max_output_bytes 1_048_576
  @default_shell "/bin/sh"
  @default_success_exit_codes [0]

  @emitted_events_key {__MODULE__, :emitted_events}

  defmodule RunState do
    @moduledoc false
    @enforce_keys [:run, :from, :task_ref, :task_pid]
    @type t :: %__MODULE__{
            run: map(),
            from: GenServer.from(),
            task_ref: reference(),
            task_pid: pid(),
            os_pid: pos_integer() | nil,
            cancelled: boolean()
          }
    defstruct [:run, :from, :task_ref, :task_pid, :os_pid, cancelled: false]
  end

  # ============================================================================
  # Public API
  # ============================================================================

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

  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  # ============================================================================
  # ProviderAdapter Behaviour Implementation
  # ============================================================================

  @impl ProviderAdapter
  def name(_adapter), do: "shell"

  @impl ProviderAdapter
  def capabilities(adapter) when is_pid(adapter) or is_atom(adapter) do
    GenServer.call(adapter, :capabilities)
  end

  @impl ProviderAdapter
  def execute(adapter, run, session, opts \\ []) do
    timeout = ProviderAdapter.resolve_execute_timeout(opts)
    GenServer.call(adapter, {:execute, run, session, opts}, timeout)
  end

  @impl ProviderAdapter
  def cancel(adapter, run_id) do
    GenServer.call(adapter, {:cancel, run_id})
  end

  @impl ProviderAdapter
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
          timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
          max_output_bytes: Keyword.get(opts, :max_output_bytes, @default_max_output_bytes),
          env: opts |> Keyword.get(:env, []) |> normalize_env(),
          shell: Keyword.get(opts, :shell, @default_shell),
          allowed_commands: normalize_command_list(Keyword.get(opts, :allowed_commands)),
          denied_commands: normalize_command_list(Keyword.get(opts, :denied_commands)),
          success_exit_codes: Keyword.get(opts, :success_exit_codes, @default_success_exit_codes),
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
    {:reply, "shell", state}
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
      task_ref: task.ref,
      task_pid: task.pid,
      os_pid: nil,
      cancelled: false
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

        if run_state.os_pid do
          kill_os_process(run_state.os_pid)
        end

        if run_state.task_pid do
          send(run_state.task_pid, {:cancelled_notification, run_id})
          Process.exit(run_state.task_pid, :kill)
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
        result =
          case Map.get(state.active_runs, run_id) do
            %RunState{task_ref: ^task_ref, cancelled: true} ->
              {:error, Error.new(:cancelled, "Run was cancelled")}

            _ ->
              {:error,
               Error.new(
                 :internal_error,
                 "Execution worker exited before returning a result: #{inspect(reason)}"
               )}
          end

        GenServer.reply(from, result)

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
        if File.dir?(cwd) do
          {:ok, cwd}
        else
          {:error, Error.new(:validation_error, "cwd does not exist: #{cwd}")}
        end

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

    with {:ok, parsed} <- parse_input(run.input, state),
         :ok <- validate_command(parsed.validation_command, state) do
      ctx = %{
        run: run,
        session: session,
        event_callback: event_callback,
        stdout: "",
        stderr: "",
        exit_code: 0,
        duration_ms: 0,
        timed_out: false
      }

      execute_shell_command(ctx, parsed, state)
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp execute_shell_command(ctx, parsed, state) do
    if cancelled?() do
      emit_event(ctx, :run_cancelled, %{})
      {:error, Error.new(:cancelled, "Run was cancelled")}
    else
      emit_event(ctx, :run_started, %{
        cwd: parsed.cwd,
        command: parsed.display_command
      })

      tool_call_id = generate_tool_call_id()

      emit_event(ctx, :tool_call_started, %{
        tool_call_id: tool_call_id,
        tool_name: "bash",
        tool_input: %{command: parsed.command, args: parsed.args, cwd: parsed.cwd}
      })

      on_output = build_on_output_callback(ctx, parsed.streaming)
      exec_opts = build_exec_opts(parsed, state, on_output)

      case Exec.run(parsed.command, parsed.args, exec_opts) do
        {:ok, result} ->
          finished_ctx = %{
            ctx
            | stdout: result.stdout,
              stderr: result.stderr,
              exit_code: result.exit_code,
              duration_ms: result.duration_ms,
              timed_out: result.timed_out
          }

          handle_exec_result(finished_ctx, tool_call_id, state.success_exit_codes)

        {:error, %Error{} = error} ->
          emit_event(ctx, :tool_call_failed, %{
            tool_call_id: tool_call_id,
            tool_name: "bash",
            tool_output: %{output: "", exit_code: nil}
          })

          emit_event(ctx, :error_occurred, %{
            error_code: error.code,
            error_message: error.message
          })

          emit_event(ctx, :run_failed, %{
            error_code: error.code
          })

          {:error, error}
      end
    end
  end

  defp handle_exec_result(ctx, tool_call_id, success_exit_codes) do
    cond do
      ctx.timed_out ->
        emit_event(ctx, :tool_call_failed, %{
          tool_call_id: tool_call_id,
          tool_name: "bash",
          tool_output: %{
            output: ctx.stdout,
            exit_code: ctx.exit_code,
            duration_ms: ctx.duration_ms,
            timed_out: true
          }
        })

        emit_event(ctx, :error_occurred, %{
          error_code: :command_timeout,
          error_message: "Command timed out after #{ctx.duration_ms}ms"
        })

        emit_event(ctx, :run_failed, %{
          error_code: :command_timeout,
          duration_ms: ctx.duration_ms
        })

        build_result(ctx)

      ctx.exit_code in success_exit_codes ->
        emit_event(ctx, :tool_call_completed, %{
          tool_call_id: tool_call_id,
          tool_name: "bash",
          tool_output: %{
            output: ctx.stdout,
            exit_code: ctx.exit_code,
            duration_ms: ctx.duration_ms
          }
        })

        emit_event(ctx, :message_received, %{
          content: ctx.stdout,
          role: "tool"
        })

        emit_event(ctx, :run_completed, %{
          stop_reason: "exit_code_#{ctx.exit_code}",
          exit_code: ctx.exit_code,
          duration_ms: ctx.duration_ms
        })

        build_result(ctx)

      true ->
        emit_event(ctx, :tool_call_failed, %{
          tool_call_id: tool_call_id,
          tool_name: "bash",
          tool_output: %{
            output: ctx.stdout,
            exit_code: ctx.exit_code,
            duration_ms: ctx.duration_ms
          }
        })

        emit_event(ctx, :error_occurred, %{
          error_code: :command_failed,
          error_message: "Command exited with code #{ctx.exit_code}"
        })

        emit_event(ctx, :run_failed, %{
          error_code: :command_failed,
          exit_code: ctx.exit_code,
          duration_ms: ctx.duration_ms
        })

        build_result(ctx)
    end
  end

  defp parse_input(input, state) when is_binary(input) do
    user_command = String.trim(input)

    {:ok,
     %{
       command: state.shell,
       args: ["-c", user_command],
       cwd: state.cwd,
       env: state.env,
       timeout_ms: state.timeout_ms,
       streaming: false,
       validation_command: extract_first_token(user_command) || Path.basename(state.shell),
       display_command: user_command
     }}
  end

  defp parse_input(%{messages: messages}, state) when is_list(messages) do
    content =
      messages
      |> Enum.filter(fn msg -> msg[:role] == "user" || msg["role"] == "user" end)
      |> Enum.map_join("\n", fn msg -> msg[:content] || msg["content"] || "" end)

    parse_input(content, state)
  end

  defp parse_input(%{"messages" => messages}, state) when is_list(messages) do
    parse_input(%{messages: messages}, state)
  end

  defp parse_input(%{} = input, state) do
    command = Map.get(input, :command) || Map.get(input, "command")

    if is_binary(command) and command != "" do
      args =
        input
        |> Map.get(:args, Map.get(input, "args", []))
        |> normalize_args()

      cwd = Map.get(input, :cwd, Map.get(input, "cwd", state.cwd))
      env = input |> Map.get(:env, Map.get(input, "env", state.env)) |> normalize_env()

      timeout_ms =
        Map.get(input, :timeout_ms, Map.get(input, "timeout_ms", state.timeout_ms))
        |> normalize_timeout(state.timeout_ms)

      streaming = Map.get(input, :streaming, Map.get(input, "streaming", false)) == true

      {:ok,
       %{
         command: command,
         args: args,
         cwd: cwd,
         env: env,
         timeout_ms: timeout_ms,
         streaming: streaming,
         validation_command: command,
         display_command: Enum.join([command | args], " ")
       }}
    else
      {:error, Error.new(:validation_error, "input.command is required")}
    end
  end

  defp parse_input(_input, _state) do
    {:error, Error.new(:validation_error, "Unsupported input format for shell execution")}
  end

  defp normalize_args(args) when is_list(args) do
    Enum.map(args, &to_string/1)
  end

  defp normalize_args(_), do: []

  defp normalize_timeout(timeout_ms, _default_timeout)
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: timeout_ms

  defp normalize_timeout(_, default_timeout), do: default_timeout

  defp build_on_output_callback(ctx, true) do
    fn
      {:stdout, chunk} ->
        emit_event(ctx, :message_streamed, %{content: chunk, delta: chunk})

      _ ->
        :ok
    end
  end

  defp build_on_output_callback(_ctx, _streaming), do: nil

  defp build_exec_opts(parsed, state, nil) do
    [
      cwd: parsed.cwd,
      timeout_ms: parsed.timeout_ms,
      max_output_bytes: state.max_output_bytes,
      env: parsed.env
    ]
  end

  defp build_exec_opts(parsed, state, on_output) do
    [
      cwd: parsed.cwd,
      timeout_ms: parsed.timeout_ms,
      max_output_bytes: state.max_output_bytes,
      env: parsed.env,
      on_output: on_output
    ]
  end

  defp validate_command(command, state) do
    base_name = command |> to_string() |> Path.basename()

    cond do
      is_list(state.denied_commands) and base_name in state.denied_commands ->
        {:error, Error.new(:policy_violation, "Command '#{base_name}' is denied")}

      is_list(state.allowed_commands) and base_name not in state.allowed_commands ->
        {:error,
         Error.new(:policy_violation, "Command '#{base_name}' is not in the allowed list")}

      true ->
        :ok
    end
  end

  defp extract_first_token(command) when is_binary(command) do
    case Regex.run(~r/^\s*([^\s|&;<>]+)/, command) do
      [_, token] -> token
      _ -> nil
    end
  end

  defp cancelled? do
    receive do
      {:cancelled_notification, _run_id} -> true
    after
      0 -> false
    end
  end

  defp generate_tool_call_id do
    "tc_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  defp emit_event(ctx, type, data) do
    event = %{
      type: type,
      timestamp: DateTime.utc_now(),
      session_id: ctx.session.id,
      run_id: ctx.run.id,
      data: data,
      provider: :shell
    }

    if ctx.event_callback do
      ctx.event_callback.(event)
    end

    append_emitted_event(event)
    event
  end

  defp build_result(ctx) do
    output = %{
      content: ctx.stdout,
      exit_code: ctx.exit_code,
      stderr: ctx.stderr,
      duration_ms: ctx.duration_ms,
      timed_out: ctx.timed_out,
      tool_calls: []
    }

    {:ok,
     %{
       output: output,
       token_usage: %{input_tokens: 0, output_tokens: 0},
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

  defp normalize_env(env) when is_map(env) do
    Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_env(env) when is_list(env) do
    Enum.flat_map(env, fn
      {k, v} -> [{to_string(k), to_string(v)}]
      _ -> []
    end)
  end

  defp normalize_env(_), do: []

  defp normalize_command_list(nil), do: nil

  defp normalize_command_list(commands) when is_list(commands) do
    Enum.map(commands, fn command -> command |> to_string() |> Path.basename() end)
  end

  defp normalize_command_list(_), do: nil

  defp kill_os_process(nil), do: :ok

  defp kill_os_process(os_pid) when is_integer(os_pid) and os_pid > 0 do
    _ = System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp build_capabilities do
    [
      %Capability{
        name: "command_execution",
        type: :code_execution,
        enabled: true,
        description: "Shell command execution"
      },
      %Capability{
        name: "streaming",
        type: :sampling,
        enabled: true,
        description: "Real-time output streaming"
      }
    ]
  end
end
