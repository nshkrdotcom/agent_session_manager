defmodule ASM.Transport.Port do
  @moduledoc """
  Lease-aware transport implementation with demand-driven fanout.

  Supports two operation modes:

  - injected mode (tests): callers push decoded maps via `inject/2`
  - subprocess mode (live): this process owns an erlexec subprocess and decodes JSONL output
  """

  use GenServer

  require Logger

  alias ASM.Error
  alias ASM.Exec
  alias ASM.Protocol
  alias ASM.TaskSupport
  alias ASM.Transport

  @behaviour Transport

  @default_timeout_ms 60_000
  @default_headless_timeout_ms 5_000
  @default_max_diagnostic_lines 5
  @default_max_diagnostic_line_length 240
  @default_max_stdout_buffer_bytes 1_048_576
  @default_max_stderr_buffer_bytes 65_536
  @default_max_lines_per_batch 200
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
            pending_lines: :queue.new(),
            drain_scheduled?: false,
            overflowed?: false,
            max_stdout_buffer_bytes: @default_max_stdout_buffer_bytes,
            stderr_buffer: "",
            max_stderr_buffer_bytes: @default_max_stderr_buffer_bytes,
            finalize_timer_ref: nil,
            timeout_ms: @default_timeout_ms,
            timeout_ref: nil,
            startup_lease_timeout_ms: nil,
            startup_lease_timeout_ref: nil,
            headless_timeout_ms: @default_headless_timeout_ms,
            headless_timeout_ref: nil,
            pending_calls: %{},
            task_supervisor: ASM.TaskSupervisor,
            diagnostics: [],
            max_diagnostic_lines: @default_max_diagnostic_lines,
            max_diagnostic_line_length: @default_max_diagnostic_line_length,
            output_mode: :jsonl,
            success_exit_codes: [0]

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
          pending_lines: :queue.queue(binary()),
          drain_scheduled?: boolean(),
          overflowed?: boolean(),
          max_stdout_buffer_bytes: pos_integer(),
          stderr_buffer: binary(),
          max_stderr_buffer_bytes: pos_integer(),
          finalize_timer_ref: reference() | nil,
          timeout_ms: pos_integer(),
          timeout_ref: reference() | nil,
          startup_lease_timeout_ms: pos_integer() | nil,
          startup_lease_timeout_ref: reference() | nil,
          headless_timeout_ms: pos_integer() | :infinity,
          headless_timeout_ref: reference() | nil,
          pending_calls: %{
            optional(reference()) => {GenServer.from(), :send_input | :end_input | :interrupt}
          },
          task_supervisor: pid() | atom(),
          diagnostics: [String.t()],
          max_diagnostic_lines: pos_integer(),
          max_diagnostic_line_length: pos_integer(),
          output_mode: :jsonl | :text,
          success_exit_codes: [non_neg_integer()]
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
  @spec end_input(pid()) :: :ok | {:error, Error.t()}
  def end_input(pid), do: GenServer.call(pid, :end_input)

  @impl true
  def interrupt(pid), do: GenServer.call(pid, :interrupt)

  @impl true
  def close(pid), do: GenServer.call(pid, :close)

  @impl true
  def health(pid), do: GenServer.call(pid, :health)

  @impl true
  @spec stderr(pid()) :: String.t()
  def stderr(pid), do: GenServer.call(pid, :stderr)

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

    headless_timeout_ms =
      Keyword.get(
        opts,
        :headless_timeout_ms,
        app_default(:transport_headless_timeout_ms, @default_headless_timeout_ms)
      )

    max_stdout_buffer_bytes =
      Keyword.get(
        opts,
        :max_stdout_buffer_bytes,
        app_default(:max_stdout_buffer_bytes, @default_max_stdout_buffer_bytes)
      )

    max_stderr_buffer_bytes =
      Keyword.get(
        opts,
        :max_stderr_buffer_bytes,
        app_default(:max_stderr_buffer_bytes, @default_max_stderr_buffer_bytes)
      )

    task_supervisor = Keyword.get(opts, :task_supervisor, ASM.TaskSupervisor)
    output_mode = normalize_output_mode(Keyword.get(opts, :output_mode, :jsonl))
    success_exit_codes = normalize_success_exit_codes(Keyword.get(opts, :success_exit_codes, [0]))

    state = %__MODULE__{
      queue_limit: normalize_queue_limit(queue_limit),
      overflow_policy: normalize_overflow_policy(overflow_policy),
      timeout_ms: normalize_timeout(timeout_ms),
      startup_lease_timeout_ms: startup_lease_timeout_ms,
      headless_timeout_ms: normalize_headless_timeout(headless_timeout_ms),
      max_stdout_buffer_bytes: normalize_max_stdout_buffer_bytes(max_stdout_buffer_bytes),
      max_stderr_buffer_bytes: normalize_max_stderr_buffer_bytes(max_stderr_buffer_bytes),
      task_supervisor: task_supervisor,
      max_diagnostic_lines: max(max_diagnostic_lines, 1),
      max_diagnostic_line_length: max(max_diagnostic_line_length, 16),
      output_mode: output_mode,
      success_exit_codes: success_exit_codes
    }

    case maybe_start_subprocess(opts, state) do
      {:ok, next_state} -> {:ok, next_state}
      {:error, reason} -> {:stop, {:transport_start_failed, reason}}
    end
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

  def handle_call({:send_input, input, opts}, from, %__MODULE__{subprocess: {pid, _}} = state) do
    append_newline? = Keyword.get(opts, :append_newline, true)

    case start_io_task(state, fn -> send_payload(pid, input, append_newline?) end) do
      {:ok, task} ->
        pending_calls = Map.put(state.pending_calls, task.ref, {from, :send_input})
        {:noreply, %{state | pending_calls: pending_calls}}

      {:error, reason} ->
        {:reply, {:error, transport_error("send task failed: #{inspect(reason)}")}, state}
    end
  end

  def handle_call(:end_input, _from, %__MODULE__{subprocess: nil} = state) do
    {:reply, {:error, transport_error("transport input unavailable: no subprocess")}, state}
  end

  def handle_call(:end_input, from, %__MODULE__{subprocess: {pid, _}} = state) do
    case start_io_task(state, fn -> send_eof(pid) end) do
      {:ok, task} ->
        pending_calls = Map.put(state.pending_calls, task.ref, {from, :end_input})
        {:noreply, %{state | pending_calls: pending_calls}}

      {:error, reason} ->
        {:reply, {:error, transport_error("end_input task failed: #{inspect(reason)}")}, state}
    end
  end

  def handle_call(:interrupt, _from, %__MODULE__{subprocess: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:interrupt, from, %__MODULE__{subprocess: {pid, _}} = state) do
    case start_io_task(state, fn -> interrupt_subprocess(pid) end) do
      {:ok, task} ->
        pending_calls = Map.put(state.pending_calls, task.ref, {from, :interrupt})
        {:noreply, %{state | pending_calls: pending_calls}}

      {:error, _reason} ->
        {:reply, :ok, state}
    end
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

  def handle_call(:stderr, _from, state) do
    {:reply, state.stderr_buffer, state}
  end

  def handle_call({:attach, run_pid}, _from, %__MODULE__{leasee: nil} = state)
      when is_pid(run_pid) do
    ref = Process.monitor(run_pid)

    state =
      state
      |> cancel_startup_lease_timeout()
      |> cancel_headless_timeout()

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

    next_state =
      state
      |> Map.put(:leasee, nil)
      |> Map.put(:leasee_ref, nil)
      |> Map.put(:pending_demand, 0)
      |> schedule_headless_timeout()

    {:reply, :ok, next_state}
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

    state =
      state
      |> reset_timeout()
      |> append_stdout_data(data)

    case drain_stdout_lines(state, @default_max_lines_per_batch) do
      {:ok, next_state} ->
        {:noreply, maybe_schedule_drain(next_state)}

      {:stop, reason, next_state} ->
        {:stop, reason, next_state}
    end
  end

  def handle_info({:stderr, os_pid, data}, %__MODULE__{subprocess: {_pid, os_pid}} = state) do
    data = IO.iodata_to_binary(data)
    stderr_buffer = append_stderr_data(state.stderr_buffer, data, state.max_stderr_buffer_bytes)

    {:noreply, %{state | stderr_buffer: stderr_buffer} |> reset_timeout()}
  end

  def handle_info(:drain_stdout, state) do
    state = %{state | drain_scheduled?: false}

    case drain_stdout_lines(state, @default_max_lines_per_batch) do
      {:ok, next_state} ->
        {:noreply, maybe_schedule_drain(next_state)}

      {:stop, reason, next_state} ->
        {:stop, reason, next_state}
    end
  end

  def handle_info({ref, result}, %{pending_calls: pending_calls} = state)
      when is_reference(ref) do
    case Map.pop(pending_calls, ref) do
      {nil, _} ->
        {:noreply, state}

      {{from, operation}, rest} ->
        Process.demonitor(ref, [:flush])

        state = %{state | pending_calls: rest}
        reply = normalize_pending_call_result(operation, result)

        GenServer.reply(from, reply)

        next_state =
          case {operation, reply} do
            {operation, :ok} when operation in [:send_input, :end_input] -> reset_timeout(state)
            _ -> state
          end

        {:noreply, next_state}
    end
  end

  def handle_info(
        {:DOWN, os_pid, :process, pid, reason},
        %__MODULE__{subprocess: {pid, os_pid}} = state
      ) do
    state =
      state
      |> clear_timeout()
      |> cancel_startup_lease_timeout()
      |> cancel_headless_timeout()
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
      |> Map.put(:drain_scheduled?, false)

    case drain_stdout_lines(state, @default_max_lines_per_batch) do
      {:stop, stop_reason, next_state} ->
        {:stop, stop_reason, next_state}

      {:ok, next_state} ->
        finalize_exit_after_drain(next_state, os_pid, pid, reason)
    end
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

  def handle_info(:headless_timeout, %__MODULE__{headless_timeout_ref: nil} = state) do
    {:noreply, state}
  end

  def handle_info(:headless_timeout, %__MODULE__{leasee: nil, subprocess: {pid, _}} = state) do
    stop_subprocess(pid)

    {:stop, :normal,
     %{
       state
       | headless_timeout_ref: nil,
         subprocess: nil,
         status: :closed
     }}
  catch
    _, _ ->
      {:stop, :normal,
       %{
         state
         | headless_timeout_ref: nil,
           subprocess: nil,
           status: :closed
       }}
  end

  def handle_info(:headless_timeout, state) do
    {:noreply, %{state | headless_timeout_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{leasee_ref: ref} = state) do
    next_state =
      state
      |> Map.put(:leasee, nil)
      |> Map.put(:leasee_ref, nil)
      |> Map.put(:pending_demand, 0)
      |> schedule_headless_timeout()

    {:noreply, next_state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending_calls: pending_calls} = state)
      when is_reference(ref) do
    case Map.pop(pending_calls, ref) do
      {nil, _} ->
        {:noreply, state}

      {{from, operation}, rest} ->
        state = %{state | pending_calls: rest}
        reply = normalize_pending_down_result(operation, reason)
        GenServer.reply(from, reply)
        {:noreply, state}
    end
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
      |> cancel_headless_timeout()
      |> cleanup_pending_calls()
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

  defp append_stdout_data(%__MODULE__{overflowed?: true} = state, data) do
    case drop_until_next_newline(data) do
      :none ->
        state

      {:rest, rest} ->
        state
        |> Map.put(:overflowed?, false)
        |> Map.put(:stdout_buffer, "")
        |> append_stdout_data(rest)
    end
  end

  defp append_stdout_data(state, data) do
    full = state.stdout_buffer <> data
    {complete_lines, remaining} = split_complete_lines(full)

    pending_lines =
      Enum.reduce(complete_lines, state.pending_lines, fn line, queue ->
        :queue.in(line, queue)
      end)

    state = %{state | pending_lines: pending_lines, stdout_buffer: "", overflowed?: false}

    if byte_size(remaining) > state.max_stdout_buffer_bytes do
      notify_stdout_overflow(state, byte_size(remaining))
      %{state | stdout_buffer: "", overflowed?: true}
    else
      %{state | stdout_buffer: remaining}
    end
  end

  defp notify_stdout_overflow(%__MODULE__{leasee: leasee}, size)
       when is_pid(leasee) and is_integer(size) and size > 0 do
    Transport.notify_error(leasee, {:stdout_buffer_overflow, size})
  end

  defp notify_stdout_overflow(_state, _size), do: :ok

  defp drain_stdout_lines(state, 0), do: {:ok, state}

  defp drain_stdout_lines(state, remaining) when is_integer(remaining) and remaining > 0 do
    case :queue.out(state.pending_lines) do
      {:empty, _queue} ->
        {:ok, state}

      {{:value, line}, queue} ->
        state = %{state | pending_lines: queue}

        case process_line(line, state) do
          {:ok, next_state} -> drain_stdout_lines(next_state, remaining - 1)
          {:stop, reason, next_state} -> {:stop, reason, next_state}
        end
    end
  end

  defp maybe_schedule_drain(%__MODULE__{drain_scheduled?: true} = state), do: state

  defp maybe_schedule_drain(state) do
    if :queue.is_empty(state.pending_lines) do
      state
    else
      Process.send_after(self(), :drain_stdout, 0)
      %{state | drain_scheduled?: true}
    end
  end

  defp process_line(line, %__MODULE__{output_mode: :text} = state) when is_binary(line) do
    map = %{"type" => "shell.output", "stream" => "stdout", "line" => line}
    maybe_enqueue_or_deliver(state, map)
  end

  defp process_line(line, state) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      {:ok, state}
    else
      decode_line(trimmed, state)
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

  defp flush_stdout_fragment(%__MODULE__{overflowed?: true} = state) do
    {:ok, %{state | stdout_buffer: "", overflowed?: false}}
  end

  defp flush_stdout_fragment(%__MODULE__{output_mode: :text} = state) do
    line = state.stdout_buffer
    state = %{state | stdout_buffer: "", overflowed?: false}

    if line == "" do
      {:ok, state}
    else
      process_line(line, state)
    end
  end

  defp flush_stdout_fragment(state) do
    line = trim_ascii(state.stdout_buffer)
    state = %{state | stdout_buffer: "", overflowed?: false}

    if line == "" do
      {:ok, state}
    else
      process_line(line, state)
    end
  end

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

  defp finalize_exit_after_drain(next_state, os_pid, pid, reason) do
    if :queue.is_empty(next_state.pending_lines) do
      finalize_and_stop(next_state, reason)
    else
      Process.send_after(self(), {:finalize_exit, os_pid, pid, reason}, 0)
      {:noreply, next_state}
    end
  end

  defp finalize_and_stop(next_state, reason) do
    case flush_stdout_fragment(next_state) do
      {:stop, stop_reason, terminal_state} ->
        {:stop, stop_reason, terminal_state}

      {:ok, flushed_state} ->
        terminal_state =
          flushed_state
          |> flush_queue_to_leasee()
          |> append_stderr_diagnostics()

        exit_status = extract_exit_status(reason)

        reported_exit_status =
          normalize_reported_exit_status(exit_status, terminal_state.success_exit_codes)

        maybe_notify_exit(terminal_state, reported_exit_status, terminal_state.diagnostics)

        {:stop, :normal, %{terminal_state | status: :closed, subprocess: nil}}
    end
  end

  defp maybe_start_subprocess(opts, state) do
    case Keyword.get(opts, :program) do
      program when is_binary(program) and program != "" ->
        args = Keyword.get(opts, :args, []) |> Enum.map(&to_string/1)
        cwd = Keyword.get(opts, :cwd)
        env = Keyword.get(opts, :env, %{})

        start_configured_subprocess(program, args, cwd, env, state)

      _ ->
        {:ok, state}
    end
  catch
    kind, reason ->
      logger_reason = {kind, reason}
      Logger.error("ASM transport failed to start subprocess: #{inspect(logger_reason)}")
      {:error, logger_reason}
  end

  defp start_configured_subprocess(program, args, cwd, env, state) do
    exec_opts =
      [:stdin, :stdout, :stderr, :monitor]
      |> Exec.add_cwd(cwd)
      |> Exec.add_env(env)

    with :ok <- ensure_program_available(program) do
      run_subprocess(program, args, exec_opts, state)
    end
  end

  defp run_subprocess(program, args, exec_opts, state) do
    argv = Exec.build_argv(program, args)

    case :exec.run(argv, exec_opts) do
      {:ok, pid, os_pid} ->
        next_state =
          %{state | subprocess: {pid, os_pid}, status: :open}
          |> schedule_timeout()
          |> schedule_startup_lease_timeout()
          |> schedule_headless_timeout()

        {:ok, next_state}

      {:error, reason} ->
        Logger.error("ASM transport failed to start subprocess: #{inspect(reason)}")
        {:error, reason}
    end
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

  defp schedule_headless_timeout(%__MODULE__{headless_timeout_ref: ref} = state)
       when not is_nil(ref),
       do: state

  defp schedule_headless_timeout(%__MODULE__{headless_timeout_ms: :infinity} = state), do: state

  defp schedule_headless_timeout(%__MODULE__{leasee: leasee} = state) when is_pid(leasee),
    do: state

  defp schedule_headless_timeout(%__MODULE__{subprocess: nil} = state), do: state

  defp schedule_headless_timeout(%__MODULE__{headless_timeout_ms: timeout_ms} = state)
       when is_integer(timeout_ms) and timeout_ms > 0 do
    timer_ref = Process.send_after(self(), :headless_timeout, timeout_ms)
    %{state | headless_timeout_ref: timer_ref}
  end

  defp schedule_headless_timeout(state), do: state

  defp cancel_headless_timeout(%__MODULE__{headless_timeout_ref: nil} = state), do: state

  defp cancel_headless_timeout(state) do
    _ = Process.cancel_timer(state.headless_timeout_ref, async: false, info: false)
    flush_headless_timeout_message()
    %{state | headless_timeout_ref: nil}
  end

  defp flush_headless_timeout_message do
    receive do
      :headless_timeout -> :ok
    after
      0 -> :ok
    end
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

  defp start_io_task(state, fun) when is_function(fun, 0) do
    TaskSupport.async_nolink(state.task_supervisor, fun)
  end

  defp send_payload(pid, input, append_newline?) do
    payload = normalize_input(input, append_newline?)
    :exec.send(pid, payload)
    :ok
  catch
    kind, reason -> {:error, {:send_failed, {kind, reason}}}
  end

  defp send_eof(pid) when is_pid(pid) do
    :exec.send(pid, :eof)
    :ok
  catch
    kind, reason -> {:error, {:send_failed, {kind, reason}}}
  end

  defp interrupt_subprocess(pid) when is_pid(pid) do
    _ = :exec.kill(pid, 2)
    :ok
  catch
    _, _ -> {:error, :not_connected}
  end

  defp normalize_pending_call_result(:send_input, :ok), do: :ok
  defp normalize_pending_call_result(:end_input, :ok), do: :ok

  defp normalize_pending_call_result(:send_input, {:error, reason}) do
    {:error, transport_error("send failed: #{inspect(reason)}")}
  end

  defp normalize_pending_call_result(:end_input, {:error, reason}) do
    {:error, transport_error("end_input failed: #{inspect(reason)}")}
  end

  defp normalize_pending_call_result(:send_input, other) do
    {:error, transport_error("send failed: #{inspect(other)}")}
  end

  defp normalize_pending_call_result(:end_input, other) do
    {:error, transport_error("end_input failed: #{inspect(other)}")}
  end

  defp normalize_pending_call_result(:interrupt, _result), do: :ok

  defp normalize_pending_down_result(:send_input, reason) do
    {:error, transport_error("send failed: #{inspect(reason)}")}
  end

  defp normalize_pending_down_result(:end_input, reason) do
    {:error, transport_error("end_input failed: #{inspect(reason)}")}
  end

  defp normalize_pending_down_result(:interrupt, _reason), do: :ok

  defp cleanup_pending_calls(%__MODULE__{pending_calls: pending_calls} = state)
       when map_size(pending_calls) == 0,
       do: state

  defp cleanup_pending_calls(%__MODULE__{pending_calls: pending_calls} = state) do
    Enum.each(pending_calls, fn {ref, {from, operation}} ->
      Process.demonitor(ref, [:flush])

      reply =
        case operation do
          operation when operation in [:send_input, :end_input] ->
            {:error, transport_error("transport stopped")}

          :interrupt ->
            :ok
        end

      GenServer.reply(from, reply)
    end)

    %{state | pending_calls: %{}}
  end

  defp split_complete_lines(""), do: {[], ""}

  defp split_complete_lines(data) do
    case :binary.split(data, "\n", [:global]) do
      [single] ->
        {[], single}

      parts ->
        {complete, [rest]} = Enum.split(parts, length(parts) - 1)
        {Enum.map(complete, &strip_trailing_cr/1), rest}
    end
  end

  defp drop_until_next_newline(data) when is_binary(data) do
    case :binary.match(data, "\n") do
      :nomatch ->
        :none

      {idx, 1} ->
        rest_offset = idx + 1
        rest_size = byte_size(data) - rest_offset
        {:rest, :binary.part(data, rest_offset, rest_size)}
    end
  end

  defp strip_trailing_cr(line) when is_binary(line) do
    size = byte_size(line)

    if size > 0 and :binary.at(line, size - 1) == ?\r do
      :binary.part(line, 0, size - 1)
    else
      line
    end
  end

  defp trim_ascii(data) when is_binary(data) do
    data
    |> trim_ascii_leading()
    |> trim_ascii_trailing()
  end

  defp trim_ascii_leading(<<char, rest::binary>>) when char in [9, 10, 11, 12, 13, 32],
    do: trim_ascii_leading(rest)

  defp trim_ascii_leading(data), do: data

  defp trim_ascii_trailing(data) when is_binary(data) do
    do_trim_ascii_trailing(data, byte_size(data) - 1)
  end

  defp do_trim_ascii_trailing(_data, -1), do: ""

  defp do_trim_ascii_trailing(data, idx) do
    case :binary.at(data, idx) do
      char when char in [9, 10, 11, 12, 13, 32] ->
        do_trim_ascii_trailing(data, idx - 1)

      _ ->
        :binary.part(data, 0, idx + 1)
    end
  end

  defp normalize_input(input, append_newline?) when is_binary(input) do
    if append_newline? and not String.ends_with?(input, "\n"), do: input <> "\n", else: input
  end

  defp normalize_input(input, append_newline?) do
    input
    |> to_string()
    |> normalize_input(append_newline?)
  end

  defp append_stderr_data(_buffer, _data, max_bytes)
       when not is_integer(max_bytes) or max_bytes <= 0,
       do: ""

  defp append_stderr_data(buffer, data, max_bytes) do
    combined = buffer <> data
    combined_size = byte_size(combined)

    if combined_size <= max_bytes do
      combined
    else
      :binary.part(combined, combined_size - max_bytes, max_bytes)
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

  defp normalize_headless_timeout(:infinity), do: :infinity
  defp normalize_headless_timeout(nil), do: :infinity
  defp normalize_headless_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_headless_timeout(_), do: @default_headless_timeout_ms

  defp normalize_max_stdout_buffer_bytes(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_stdout_buffer_bytes(_), do: @default_max_stdout_buffer_bytes

  defp normalize_max_stderr_buffer_bytes(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_stderr_buffer_bytes(_), do: @default_max_stderr_buffer_bytes

  defp normalize_output_mode(:jsonl), do: :jsonl
  defp normalize_output_mode(:text), do: :text
  defp normalize_output_mode(_), do: :jsonl

  defp normalize_success_exit_codes(codes) when is_list(codes) do
    normalized =
      codes
      |> Enum.filter(&(is_integer(&1) and &1 >= 0))
      |> Enum.map(&normalize_exit_status/1)
      |> Enum.uniq()

    if normalized == [], do: [0], else: normalized
  end

  defp normalize_success_exit_codes(_), do: [0]

  defp normalize_reported_exit_status(exit_status, success_exit_codes)
       when is_integer(exit_status) and is_list(success_exit_codes) do
    if exit_status in success_exit_codes, do: 0, else: exit_status
  end

  defp ensure_program_available(program) when is_binary(program) do
    cond do
      String.contains?(program, "/") ->
        if File.regular?(program) do
          :ok
        else
          {:error, {:program_not_found, program}}
        end

      is_binary(System.find_executable(program)) ->
        :ok

      true ->
        {:error, {:program_not_found, program}}
    end
  end

  defp app_default(key, default) do
    Application.get_env(:agent_session_manager, key, default)
  end

  defp transport_error(message) do
    Error.new(:transport_error, :transport, message)
  end
end
