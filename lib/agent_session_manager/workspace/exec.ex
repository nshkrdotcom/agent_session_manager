defmodule AgentSessionManager.Workspace.Exec do
  @moduledoc """
  Low-level shell command execution with timeout, output capture, and cancellation.

  This module provides direct command execution without session/run lifecycle
  overhead. For managed execution with events and policies, use ShellAdapter.
  """

  alias AgentSessionManager.Core.Error

  @default_timeout_ms 30_000
  @default_max_output_bytes 1_048_576

  @type exec_result :: %{
          command: String.t(),
          args: [String.t()],
          cwd: String.t(),
          exit_code: integer(),
          stdout: String.t(),
          stderr: String.t(),
          duration_ms: non_neg_integer(),
          timed_out: boolean()
        }

  @type stream_chunk ::
          {:stdout, binary()}
          | {:stderr, binary()}
          | {:exit, integer()}
          | {:error, term()}

  @type exec_opts :: [
          {:cwd, String.t()}
          | {:timeout_ms, pos_integer()}
          | {:max_output_bytes, pos_integer()}
          | {:env, [{String.t(), String.t()}]}
          | {:shell, String.t()}
          | {:on_output, (stream_chunk() -> any())}
        ]

  @spec run(String.t(), [String.t()], exec_opts()) :: {:ok, exec_result()} | {:error, Error.t()}
  def run(command, args \\ [], opts \\ [])

  def run(command, args, opts) when is_binary(command) and is_list(args) do
    start_time = System.monotonic_time(:millisecond)

    with {:ok, cwd} <- resolve_cwd(opts),
         {:ok, command_path} <- resolve_command_path(command) do
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      max_output_bytes = Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)
      env = opts |> Keyword.get(:env, []) |> normalize_env()
      on_output = Keyword.get(opts, :on_output)

      run_ref = make_ref()
      owner = self()

      task =
        Task.async(fn ->
          run_with_port(command_path, args, cwd, env, max_output_bytes, on_output, owner, run_ref)
        end)

      case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, port_result}} ->
          duration_ms = elapsed_ms(start_time)

          {:ok,
           %{
             command: command,
             args: args,
             cwd: cwd,
             exit_code: port_result.exit_code,
             stdout: port_result.stdout,
             stderr: "",
             duration_ms: duration_ms,
             timed_out: false
           }}

        {:ok, {:error, %Error{} = error}} ->
          {:error, error}

        nil ->
          kill_os_process(find_os_pid(run_ref))

          {:ok,
           %{
             command: command,
             args: args,
             cwd: cwd,
             exit_code: 124,
             stdout: "",
             stderr: "",
             duration_ms: elapsed_ms(start_time),
             timed_out: true
           }}

        {:exit, _reason} ->
          {:error, Error.new(:internal_error, "Command execution task crashed")}
      end
    end
  rescue
    exception ->
      {:error, Error.new(:internal_error, Exception.message(exception))}
  end

  @spec run_streaming(String.t(), [String.t()], exec_opts()) :: Enumerable.t()
  def run_streaming(command, args \\ [], opts \\ []) do
    Stream.resource(
      fn ->
        case prepare_stream_state(command, args, opts) do
          {:ok, state} -> state
          {:error, reason} -> {:failed_start, reason}
        end
      end,
      &stream_next/1,
      &stream_after/1
    )
  end

  defp run_with_port(command_path, args, cwd, env, max_output_bytes, on_output, owner, run_ref) do
    args_charlist = Enum.map(args, &String.to_charlist(to_string(&1)))

    port_opts = [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:cd, cwd},
      {:args, args_charlist},
      {:env, env}
    ]

    port = Port.open({:spawn_executable, command_path}, port_opts)
    send(owner, {:workspace_exec_os_pid, run_ref, get_os_pid(port)})

    collect_port_output(port, %{stdout: "", exit_code: 0}, max_output_bytes, on_output)
  rescue
    exception ->
      {:error, Error.new(:internal_error, Exception.message(exception))}
  end

  defp collect_port_output(port, acc, max_output_bytes, on_output) do
    receive do
      {^port, {:data, data}} ->
        maybe_emit_chunk(on_output, {:stdout, data})

        new_stdout = append_limited(acc.stdout, data, max_output_bytes)
        collect_port_output(port, %{acc | stdout: new_stdout}, max_output_bytes, on_output)

      {^port, {:exit_status, exit_code}} ->
        {:ok, %{acc | exit_code: exit_code}}
    end
  end

  defp prepare_stream_state(command, args, opts) do
    with {:ok, cwd} <- resolve_cwd(opts),
         {:ok, command_path} <- resolve_command_path(command) do
      timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
      env = opts |> Keyword.get(:env, []) |> normalize_env()
      args_charlist = Enum.map(args, &String.to_charlist(to_string(&1)))

      port_opts = [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, cwd},
        {:args, args_charlist},
        {:env, env}
      ]

      port = Port.open({:spawn_executable, command_path}, port_opts)

      {:ok,
       %{
         port: port,
         timeout_ms: timeout_ms,
         closed?: false
       }}
    end
  rescue
    exception ->
      {:error, Error.new(:internal_error, Exception.message(exception))}
  end

  defp stream_next({:failed_start, reason}) do
    {[{:error, reason}], :halted}
  end

  defp stream_next(:halted), do: {:halt, :halted}

  defp stream_next(%{port: port, timeout_ms: timeout_ms} = state) do
    receive do
      {^port, {:data, data}} ->
        {[{:stdout, data}], state}

      {^port, {:exit_status, code}} ->
        {[{:exit, code}], :halted}
    after
      timeout_ms ->
        kill_os_process(get_os_pid(port))
        {[{:exit, 124}], :halted}
    end
  end

  defp stream_after(%{port: port}) do
    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp stream_after(_), do: :ok

  defp resolve_cwd(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())

    cond do
      not is_binary(cwd) or cwd == "" ->
        {:error, Error.new(:validation_error, "cwd must be a non-empty string")}

      not File.dir?(cwd) ->
        {:error, Error.new(:validation_error, "cwd does not exist: #{cwd}")}

      true ->
        {:ok, cwd}
    end
  end

  defp resolve_command_path(command) do
    case System.find_executable(command) do
      nil -> {:error, Error.new(:command_not_found, "Command not found: #{command}")}
      path -> {:ok, path}
    end
  end

  defp normalize_env(env) when is_list(env) do
    Enum.map(env, fn
      {k, v} when is_binary(k) and is_binary(v) ->
        {String.to_charlist(k), String.to_charlist(v)}

      {k, v} ->
        {String.to_charlist(to_string(k)), String.to_charlist(to_string(v))}
    end)
  end

  defp normalize_env(_), do: []

  defp maybe_emit_chunk(nil, _chunk), do: :ok

  defp maybe_emit_chunk(on_output, chunk) when is_function(on_output, 1) do
    try do
      on_output.(chunk)
    catch
      _, _ -> :ok
    end

    :ok
  end

  defp append_limited(existing, _data, max_output_bytes)
       when byte_size(existing) >= max_output_bytes do
    existing
  end

  defp append_limited(existing, data, max_output_bytes) do
    remaining = max_output_bytes - byte_size(existing)

    cond do
      remaining <= 0 ->
        existing

      byte_size(data) <= remaining ->
        existing <> data

      true ->
        existing <> binary_part(data, 0, remaining)
    end
  end

  defp find_os_pid(run_ref) do
    receive do
      {:workspace_exec_os_pid, ^run_ref, os_pid} -> os_pid
    after
      0 -> nil
    end
  end

  defp get_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  end

  defp kill_os_process(nil), do: :ok

  defp kill_os_process(os_pid) when is_integer(os_pid) and os_pid > 0 do
    _ = System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp elapsed_ms(start_time) do
    now = System.monotonic_time(:millisecond)
    max(now - start_time, 0)
  end
end
