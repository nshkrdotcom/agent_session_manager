defmodule ASM.Transport.Port do
  @moduledoc """
  Lease-aware transport implementation with demand-driven fanout.

  Supports two operation modes:

  - injected mode (tests): callers push decoded maps via `inject/2`
  - subprocess mode (live): this process owns an erlexec subprocess and decodes JSONL output
  """

  # Phase 0 Review Notes
  # - Run.Server expects exactly these transport notifications:
  #   `{:transport_message, map}`, `{:transport_error, reason}`,
  #   and `{:transport_exit, status, diagnostics}`.
  # - Demand protocol must stay unchanged: attach leasee -> demand(n) -> deliver FIFO
  #   messages -> demand again (Run.Server uses 1-at-a-time demand).
  # - `inject/2` is a subprocess-independent test seam to push decoded maps directly,
  #   so unit tests can exercise queue/lease behavior without spawning a CLI process.
  # - Only subprocess management changes here (Port APIs -> erlexec). Lease ownership,
  #   queue semantics, overflow policies, and transport message contract remain identical.

  use GenServer

  require Logger

  alias ASM.Error
  alias ASM.Exec
  alias ASM.Protocol
  alias ASM.Transport

  @behaviour Transport

  @default_timeout_ms 60_000
  @default_max_diagnostic_lines 5
  @default_max_diagnostic_line_length 240
  @max_stderr_tail_bytes 65_536
  @finalize_delay_ms 25

  @enforce_keys []
  defstruct leasee: nil,
            leasee_ref: nil,
            queue: :queue.new(),
            pending_demand: 0,
            queue_limit: 1_000,
            overflow_policy: :fail_run,
            status: :open,
            subprocess: nil,
            stdout_buffer: "",
            stderr_buffer: "",
            finalize_timer_ref: nil,
            timeout_ms: @default_timeout_ms,
            timeout_ref: nil,
            startup_lease_timeout_ms: nil,
            startup_lease_timeout_ref: nil,
            diagnostics: [],
            max_diagnostic_lines: @default_max_diagnostic_lines,
            max_diagnostic_line_length: @default_max_diagnostic_line_length

  @type t :: %__MODULE__{
          leasee: pid() | nil,
          leasee_ref: reference() | nil,
          queue: :queue.queue(map()),
          pending_demand: non_neg_integer(),
          queue_limit: pos_integer(),
          overflow_policy: :fail_run | :drop_oldest | :block,
          status: :open | :closed,
          subprocess: {pid(), non_neg_integer()} | nil,
          stdout_buffer: binary(),
          stderr_buffer: binary(),
          finalize_timer_ref: reference() | nil,
          timeout_ms: pos_integer(),
          timeout_ref: reference() | nil,
          startup_lease_timeout_ms: pos_integer() | nil,
          startup_lease_timeout_ref: reference() | nil,
          diagnostics: [String.t()],
          max_diagnostic_lines: pos_integer(),
          max_diagnostic_line_length: pos_integer()
        }

  @impl true
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec inject(pid(), map()) :: :ok
  def inject(pid, raw_map) when is_map(raw_map) do
    GenServer.cast(pid, {:inject, raw_map})
    :ok
  end

  @impl true
  def send_input(pid, input, opts), do: GenServer.call(pid, {:send_input, input, opts})

  @impl true
  def interrupt(pid), do: GenServer.call(pid, :interrupt)

  @impl true
  def close(pid), do: GenServer.call(pid, :close)

  @impl true
  def health(pid), do: GenServer.call(pid, :health)

  @impl true
  def attach(pid, run_pid), do: GenServer.call(pid, {:attach, run_pid})

  @impl true
  def detach(pid, run_pid), do: GenServer.call(pid, {:detach, run_pid})

  @impl true
  def demand(pid, run_pid, n), do: Transport.demand(pid, run_pid, n)

  @impl true
  def init(opts) do
    queue_limit = Keyword.get(opts, :queue_limit, app_default(:queue_limit, 1_000))

    overflow_policy =
      Keyword.get(opts, :overflow_policy, app_default(:overflow_policy, :fail_run))

    timeout_ms =
      Keyword.get(
        opts,
        :transport_timeout_ms,
        app_default(:transport_timeout_ms, @default_timeout_ms)
      )

    max_diagnostic_lines = Keyword.get(opts, :max_diagnostic_lines, @default_max_diagnostic_lines)

    max_diagnostic_line_length =
      Keyword.get(opts, :max_diagnostic_line_length, @default_max_diagnostic_line_length)

    startup_lease_timeout_ms =
      normalize_startup_lease_timeout(Keyword.get(opts, :startup_lease_timeout_ms))

    state = %__MODULE__{
      queue_limit: normalize_queue_limit(queue_limit),
      overflow_policy: normalize_overflow_policy(overflow_policy),
      timeout_ms: normalize_timeout(timeout_ms),
      startup_lease_timeout_ms: startup_lease_timeout_ms,
      max_diagnostic_lines: max(max_diagnostic_lines, 1),
      max_diagnostic_line_length: max(max_diagnostic_line_length, 16)
    }

    {:ok, maybe_start_subprocess(opts, state)}
  end

  @impl true
  def handle_call(:health, _from, %__MODULE__{subprocess: {pid, _}, status: :open} = state)
      when is_pid(pid) do
    if Process.alive?(pid) do
      {:reply, :healthy, state}
    else
      {:reply, {:unhealthy, :subprocess_not_alive}, state}
    end
  end

  def handle_call(:health, _from, %__MODULE__{subprocess: nil, status: :open} = state) do
    {:reply, :healthy, state}
  end

  def handle_call(:health, _from, state) do
    {:reply, :degraded, state}
  end

  def handle_call({:send_input, _input, _opts}, _from, %__MODULE__{subprocess: nil} = state) do
    {:reply, {:error, transport_error("transport input unavailable: no subprocess")}, state}
  end

  def handle_call({:send_input, input, opts}, _from, %__MODULE__{subprocess: {pid, _}} = state) do
    append_newline? = Keyword.get(opts, :append_newline, true)
    payload = normalize_input(input, append_newline?)
    :ok = :exec.send(pid, payload)
    {:reply, :ok, reset_timeout(state)}
  catch
    kind, reason ->
      {:reply, {:error, transport_error("send failed: #{inspect({kind, reason})}")}, state}
  end

  def handle_call(:interrupt, _from, %__MODULE__{subprocess: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:interrupt, _from, %__MODULE__{subprocess: {pid, _}} = state) do
    _ = :exec.kill(pid, 2)
    {:reply, :ok, state}
  catch
    _, _ -> {:reply, :ok, state}
  end

  def handle_call(:close, _from, %__MODULE__{subprocess: nil} = state) do
    {:stop, :normal, :ok, %{state | status: :closed}}
  end

  def handle_call(:close, _from, %__MODULE__{subprocess: {pid, _}} = state) do
    stop_subprocess(pid)
    {:stop, :normal, :ok, %{state | status: :closed}}
  catch
    _, _ ->
      {:stop, :normal, :ok, %{state | status: :closed}}
  end

  def handle_call({:attach, run_pid}, _from, %__MODULE__{leasee: nil} = state)
      when is_pid(run_pid) do
    ref = Process.monitor(run_pid)
    state = cancel_startup_lease_timeout(state)

    {:reply, {:ok, :attached}, %{state | leasee: run_pid, leasee_ref: ref, pending_demand: 0}}
  end

  def handle_call({:attach, run_pid}, _from, %__MODULE__{leasee: run_pid} = state)
      when is_pid(run_pid) do
    {:reply, {:ok, :attached}, state}
  end

  def handle_call({:attach, _run_pid}, _from, state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:detach, run_pid}, _from, %__MODULE__{leasee: run_pid} = state)
      when is_pid(run_pid) do
    if state.leasee_ref, do: Process.demonitor(state.leasee_ref, [:flush])

    {:reply, :ok, %{state | leasee: nil, leasee_ref: nil, pending_demand: 0}}
  end

  def handle_call({:detach, _run_pid}, _from, state) do
    {:reply, {:error, :not_leasee}, state}
  end

  @impl true
  def handle_cast({:inject, raw_map}, state) do
    case maybe_enqueue_or_deliver(state, raw_map) do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:stop, reason, next_state} ->
        {:stop, reason, next_state}
    end
  end

  def handle_cast({:demand, run_pid, n}, %__MODULE__{leasee: run_pid} = state)
      when is_pid(run_pid) and is_integer(n) and n > 0 do
    state
    |> Map.update!(:pending_demand, &(&1 + n))
    |> deliver()
    |> then(&{:noreply, &1})
  end

  def handle_cast({:demand, _other_pid, _n}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:stdout, os_pid, data}, %__MODULE__{subprocess: {_pid, os_pid}} = state) do
    data = IO.iodata_to_binary(data)
    state = reset_timeout(state)
    {lines, remainder} = Protocol.JSONL.extract_lines(state.stdout_buffer <> data)

    case process_lines(lines, %{state | stdout_buffer: remainder}) do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:stop, reason, next_state} ->
        {:stop, reason, next_state}
    end
  end

  def handle_info({:stderr, os_pid, data}, %__MODULE__{subprocess: {_pid, os_pid}} = state) do
    data = IO.iodata_to_binary(data)
    stderr_buffer = append_stderr_data(state.stderr_buffer, data)
    {:noreply, %{state | stderr_buffer: stderr_buffer}}
  end

  def handle_info(
        {:DOWN, os_pid, :process, pid, reason},
        %__MODULE__{subprocess: {pid, os_pid}} = state
      ) do
    state =
      state
      |> clear_timeout()
      |> cancel_startup_lease_timeout()
      |> cancel_finalize_timer()

    timer_ref =
      Process.send_after(self(), {:finalize_exit, os_pid, pid, reason}, @finalize_delay_ms)

    {:noreply, %{state | finalize_timer_ref: timer_ref}}
  end

  def handle_info(
        {:finalize_exit, os_pid, pid, reason},
        %__MODULE__{subprocess: {pid, os_pid}} = state
      ) do
    state =
      state
      |> Map.put(:finalize_timer_ref, nil)
      |> flush_stdout_buffer()
      |> flush_queue_to_leasee()
      |> append_stderr_diagnostics()

    exit_status = extract_exit_status(reason)
    maybe_notify_exit(state, exit_status, state.diagnostics)

    {:stop, :normal, %{state | status: :closed, subprocess: nil}}
  end

  def handle_info(:transport_timeout, %__MODULE__{subprocess: nil} = state) do
    {:noreply, %{state | timeout_ref: nil}}
  end

  def handle_info(
        :transport_timeout,
        %__MODULE__{subprocess: {pid, _}, timeout_ms: timeout_ms} = state
      ) do
    if is_pid(state.leasee), do: Transport.notify_error(state.leasee, {:timeout, timeout_ms})

    stop_subprocess(pid)
    {:noreply, %{state | timeout_ref: nil, status: :closed}}
  catch
    _, _ ->
      {:noreply, %{state | timeout_ref: nil, status: :closed}}
  end

  def handle_info(:startup_lease_timeout, %__MODULE__{startup_lease_timeout_ref: nil} = state) do
    {:noreply, state}
  end

  def handle_info(
        :startup_lease_timeout,
        %__MODULE__{leasee: nil, subprocess: {pid, _}} = state
      ) do
    stop_subprocess(pid)

    {:stop, {:shutdown, :startup_lease_timeout},
     %{
       state
       | startup_lease_timeout_ref: nil,
         subprocess: nil,
         status: :closed
     }}
  catch
    _, _ ->
      {:stop, {:shutdown, :startup_lease_timeout},
       %{
         state
         | startup_lease_timeout_ref: nil,
           subprocess: nil,
           status: :closed
       }}
  end

  def handle_info(:startup_lease_timeout, state) do
    {:noreply, %{state | startup_lease_timeout_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{leasee_ref: ref} = state) do
    {:noreply, %{state | leasee: nil, leasee_ref: nil, pending_demand: 0}}
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    state =
      state
      |> cancel_finalize_timer()
      |> clear_timeout()
      |> cancel_startup_lease_timeout()
      |> force_stop_subprocess()

    _ = state
    :ok
  catch
    _, _ -> :ok
  end

  defp deliver(%__MODULE__{leasee: nil} = state), do: state
  defp deliver(%__MODULE__{pending_demand: 0} = state), do: state

  defp deliver(%__MODULE__{} = state) do
    case :queue.out(state.queue) do
      {{:value, raw_map}, remaining} when state.pending_demand > 0 ->
        Transport.notify_message(state.leasee, raw_map)

        %{state | queue: remaining, pending_demand: state.pending_demand - 1}
        |> deliver()

      {:empty, _same} ->
        state

      _ ->
        state
    end
  end

  defp maybe_enqueue_or_deliver(
         %__MODULE__{leasee: leasee, pending_demand: pending_demand} = state,
         raw_map
       )
       when is_pid(leasee) and pending_demand > 0 do
    Transport.notify_message(leasee, raw_map)
    {:ok, %{state | pending_demand: pending_demand - 1}}
  end

  defp maybe_enqueue_or_deliver(state, raw_map) do
    queue_len = :queue.len(state.queue)

    if queue_len < state.queue_limit do
      {:ok, %{state | queue: :queue.in(raw_map, state.queue)}}
    else
      handle_overflow(state, raw_map)
    end
  end

  defp handle_overflow(%__MODULE__{overflow_policy: :drop_oldest} = state, raw_map) do
    {_dropped, trimmed} = queue_drop_oldest(state.queue)
    {:ok, %{state | queue: :queue.in(raw_map, trimmed)}}
  end

  defp handle_overflow(%__MODULE__{overflow_policy: :block} = state, _raw_map) do
    {:ok, state}
  end

  defp handle_overflow(%__MODULE__{overflow_policy: :fail_run} = state, _raw_map) do
    if is_pid(state.leasee), do: Transport.notify_error(state.leasee, :buffer_overflow)
    {:stop, {:shutdown, :buffer_overflow}, %{state | status: :closed}}
  end

  defp process_lines(lines, state) do
    Enum.reduce_while(lines, {:ok, state}, fn line, {:ok, acc} ->
      case process_line(line, acc) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:stop, reason, next_state} -> {:halt, {:stop, reason, next_state}}
      end
    end)
  end

  defp process_line(line, state) when is_binary(line) do
    line = String.trim(line)

    if line == "" do
      {:ok, state}
    else
      decode_line(line, state)
    end
  end

  defp decode_line(line, state) do
    case Protocol.JSONL.decode_line(line) do
      {:ok, map} ->
        maybe_enqueue_or_deliver(state, map)

      {:error, :not_json_object} ->
        {:ok, append_diagnostic(state, line)}

      {:error, reason} ->
        notify_parse_error(state, line, reason)
        {:ok, append_diagnostic(state, line)}
    end
  end

  defp notify_parse_error(%__MODULE__{leasee: leasee}, line, reason)
       when is_pid(leasee) and is_binary(line) do
    if json_object_candidate?(line) do
      Transport.notify_error(leasee, {:parse_error, reason, line})
    end
  end

  defp notify_parse_error(_state, _line, _reason), do: :ok

  defp maybe_notify_exit(%__MODULE__{leasee: leasee}, status, diagnostics) when is_pid(leasee) do
    Transport.notify_exit(leasee, status, diagnostics)
  end

  defp maybe_notify_exit(_state, _status, _diagnostics), do: :ok

  defp flush_queue_to_leasee(%__MODULE__{leasee: leasee} = state) when is_pid(leasee) do
    {messages, emptied_queue} = drain_queue(state.queue, [])
    Enum.each(messages, &Transport.notify_message(leasee, &1))
    %{state | queue: emptied_queue, pending_demand: 0}
  end

  defp flush_queue_to_leasee(state), do: state

  defp drain_queue(queue, acc) do
    case :queue.out(queue) do
      {{:value, message}, remaining} -> drain_queue(remaining, [message | acc])
      {:empty, remaining} -> {Enum.reverse(acc), remaining}
    end
  end

  defp append_diagnostic(state, line) do
    line =
      line
      |> String.trim()
      |> String.slice(0, state.max_diagnostic_line_length)

    diagnostics =
      state.diagnostics
      |> Kernel.++([line])
      |> Enum.take(-state.max_diagnostic_lines)

    %{state | diagnostics: diagnostics}
  end

  defp append_stderr_diagnostics(%__MODULE__{stderr_buffer: ""} = state), do: state

  defp append_stderr_diagnostics(state) do
    state.stderr_buffer
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.reduce(state, fn line, acc -> append_diagnostic(acc, line) end)
  end

  defp json_object_candidate?(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}")
  end

  defp maybe_start_subprocess(opts, state) do
    case Keyword.get(opts, :program) do
      program when is_binary(program) and program != "" ->
        args = Keyword.get(opts, :args, []) |> Enum.map(&to_string/1)
        cwd = Keyword.get(opts, :cwd)
        env = Keyword.get(opts, :env, %{})

        exec_opts =
          [:stdin, :stdout, :stderr, :monitor]
          |> Exec.add_cwd(cwd)
          |> Exec.add_env(env)

        cmd = Exec.build_command(program, args)

        case :exec.run(cmd, exec_opts) do
          {:ok, pid, os_pid} ->
            %{state | subprocess: {pid, os_pid}, status: :open}
            |> schedule_timeout()
            |> schedule_startup_lease_timeout()

          {:error, reason} ->
            Logger.error("ASM transport failed to start subprocess: #{inspect(reason)}")
            state
        end

      _ ->
        state
    end
  catch
    kind, reason ->
      Logger.error("ASM transport failed to start subprocess: #{inspect({kind, reason})}")
      state
  end

  defp schedule_timeout(%__MODULE__{timeout_ms: timeout_ms} = state) do
    clear_timeout(state)
    |> Map.put(:timeout_ref, Process.send_after(self(), :transport_timeout, timeout_ms))
  end

  defp reset_timeout(state), do: schedule_timeout(state)

  defp clear_timeout(%__MODULE__{timeout_ref: nil} = state), do: state

  defp clear_timeout(%__MODULE__{timeout_ref: ref} = state) do
    Process.cancel_timer(ref, async: true, info: false)
    %{state | timeout_ref: nil}
  end

  defp schedule_startup_lease_timeout(
         %__MODULE__{
           startup_lease_timeout_ms: timeout_ms,
           startup_lease_timeout_ref: nil,
           leasee: nil,
           subprocess: {_pid, _os_pid}
         } = state
       )
       when is_integer(timeout_ms) and timeout_ms > 0 do
    %{
      state
      | startup_lease_timeout_ref: Process.send_after(self(), :startup_lease_timeout, timeout_ms)
    }
  end

  defp schedule_startup_lease_timeout(state), do: state

  defp cancel_startup_lease_timeout(%__MODULE__{startup_lease_timeout_ref: nil} = state),
    do: state

  defp cancel_startup_lease_timeout(%__MODULE__{startup_lease_timeout_ref: ref} = state) do
    Process.cancel_timer(ref, async: true, info: false)
    %{state | startup_lease_timeout_ref: nil}
  end

  defp cancel_finalize_timer(%__MODULE__{finalize_timer_ref: nil} = state), do: state

  defp cancel_finalize_timer(state) do
    _ = Process.cancel_timer(state.finalize_timer_ref, async: false, info: false)
    flush_finalize_message(state.subprocess)
    %{state | finalize_timer_ref: nil}
  end

  defp flush_finalize_message({pid, os_pid}) do
    receive do
      {:finalize_exit, ^os_pid, ^pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp flush_finalize_message(_), do: :ok

  defp normalize_input(input, append_newline?) when is_binary(input) do
    if append_newline? and not String.ends_with?(input, "\n"), do: input <> "\n", else: input
  end

  defp normalize_input(input, append_newline?) do
    input
    |> to_string()
    |> normalize_input(append_newline?)
  end

  defp flush_stdout_buffer(state) do
    {lines, remainder} = Protocol.JSONL.extract_lines(state.stdout_buffer)

    lines =
      if String.trim(remainder) == "" do
        lines
      else
        lines ++ [remainder]
      end

    case process_lines(lines, %{state | stdout_buffer: ""}) do
      {:ok, next_state} -> next_state
      {:stop, _reason, next_state} -> next_state
    end
  end

  defp append_stderr_data(buffer, data) do
    combined = buffer <> data
    combined_size = byte_size(combined)

    if combined_size <= @max_stderr_tail_bytes do
      combined
    else
      :binary.part(combined, combined_size - @max_stderr_tail_bytes, @max_stderr_tail_bytes)
    end
  end

  defp queue_drop_oldest(queue) do
    case :queue.out(queue) do
      {{:value, item}, remaining} -> {item, remaining}
      {:empty, remaining} -> {nil, remaining}
    end
  end

  defp force_stop_subprocess(%__MODULE__{subprocess: {pid, _}} = state) do
    stop_subprocess(pid)
    %{state | subprocess: nil, status: :closed}
  end

  defp force_stop_subprocess(state), do: state

  defp stop_subprocess(pid) when is_pid(pid) do
    :exec.stop(pid)
    _ = :exec.kill(pid, 9)
    :ok
  catch
    _, _ -> :ok
  end

  defp extract_exit_status(:normal), do: 0
  defp extract_exit_status(0), do: 0

  defp extract_exit_status({:exit_status, code}) when is_integer(code),
    do: normalize_exit_status(code)

  defp extract_exit_status({:status, code}) when is_integer(code), do: normalize_exit_status(code)
  defp extract_exit_status({:signal, signal}) when is_integer(signal), do: 128 + signal
  defp extract_exit_status(:killed), do: 137
  defp extract_exit_status(code) when is_integer(code), do: normalize_exit_status(code)
  defp extract_exit_status(_reason), do: 1

  defp normalize_exit_status(code) when code > 255 and rem(code, 256) == 0, do: div(code, 256)
  defp normalize_exit_status(code), do: code

  defp normalize_queue_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_queue_limit(_), do: 1_000

  defp normalize_overflow_policy(policy) when policy in [:fail_run, :drop_oldest, :block],
    do: policy

  defp normalize_overflow_policy(_), do: :fail_run

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout(_), do: @default_timeout_ms

  defp normalize_startup_lease_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_startup_lease_timeout(_value), do: nil

  defp app_default(key, default) do
    Application.get_env(:agent_session_manager, key, default)
  end

  defp transport_error(message) do
    Error.new(:transport_error, :transport, message)
  end
end
