defmodule ASM.Transport.Port do
  @moduledoc """
  Lease-aware transport implementation with demand-driven fanout.

  Supports two operation modes:

  - injected mode (tests): callers push decoded maps via `inject/2`
  - subprocess mode (live): this process owns an Erlang Port and decodes JSONL output
  """

  use GenServer

  alias ASM.Error
  alias ASM.Protocol
  alias ASM.Transport

  @behaviour Transport

  @default_timeout_ms 60_000
  @default_max_diagnostic_lines 5
  @default_max_diagnostic_line_length 240

  @enforce_keys []
  defstruct leasee: nil,
            leasee_ref: nil,
            queue: :queue.new(),
            pending_demand: 0,
            queue_limit: 1_000,
            overflow_policy: :fail_run,
            status: :open,
            port: nil,
            buffer: "",
            timeout_ms: @default_timeout_ms,
            timeout_ref: nil,
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
          port: port() | nil,
          buffer: binary(),
          timeout_ms: pos_integer(),
          timeout_ref: reference() | nil,
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

    state = %__MODULE__{
      queue_limit: normalize_queue_limit(queue_limit),
      overflow_policy: normalize_overflow_policy(overflow_policy),
      timeout_ms: normalize_timeout(timeout_ms),
      max_diagnostic_lines: max(max_diagnostic_lines, 1),
      max_diagnostic_line_length: max(max_diagnostic_line_length, 16)
    }

    {:ok, maybe_start_subprocess(opts, state)}
  end

  @impl true
  def handle_call(:health, _from, %__MODULE__{status: :open} = state) do
    {:reply, :healthy, state}
  end

  def handle_call(:health, _from, state) do
    {:reply, :degraded, state}
  end

  def handle_call({:send_input, _input, _opts}, _from, %__MODULE__{port: nil} = state) do
    {:reply, {:error, transport_error("transport input unavailable: no subprocess")}, state}
  end

  def handle_call({:send_input, input, opts}, _from, %__MODULE__{port: port} = state) do
    append_newline? = Keyword.get(opts, :append_newline, true)
    payload = normalize_input(input, append_newline?)
    true = Port.command(port, payload)
    {:reply, :ok, reset_timeout(state)}
  rescue
    error ->
      {:reply,
       {:error, Error.new(:transport_error, :transport, Exception.message(error), cause: error)},
       state}
  end

  def handle_call(:interrupt, _from, %__MODULE__{port: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:interrupt, _from, %__MODULE__{port: port} = state) do
    maybe_notify_exit(state, 130)
    Port.close(port)
    {:reply, :ok, %{state | status: :closed}}
  rescue
    _ ->
      maybe_notify_exit(state, 130)
      {:reply, :ok, %{state | status: :closed}}
  end

  def handle_call(:close, _from, %__MODULE__{port: nil} = state) do
    {:stop, :normal, :ok, %{state | status: :closed}}
  end

  def handle_call(:close, _from, %__MODULE__{port: port} = state) do
    Port.close(port)
    {:stop, :normal, :ok, %{state | status: :closed}}
  rescue
    _ ->
      {:stop, :normal, :ok, %{state | status: :closed}}
  end

  def handle_call({:attach, run_pid}, _from, %__MODULE__{leasee: nil} = state)
      when is_pid(run_pid) do
    ref = Process.monitor(run_pid)

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
  def handle_info({port, {:data, chunk}}, %__MODULE__{port: port} = state)
      when is_binary(chunk) do
    state = reset_timeout(state)
    {lines, remainder} = Protocol.JSONL.extract_lines(state.buffer <> chunk)

    case process_lines(lines, %{state | buffer: remainder}) do
      {:ok, next_state} ->
        {:noreply, next_state}

      {:stop, reason, next_state} ->
        {:stop, reason, next_state}
    end
  end

  def handle_info({port, {:exit_status, status}}, %__MODULE__{port: port} = state)
      when is_integer(status) do
    state =
      state
      |> clear_timeout()
      |> flush_queue_to_leasee()

    maybe_notify_exit(state, status)
    {:stop, :normal, %{state | status: :closed, port: nil}}
  end

  def handle_info({port, :closed}, %__MODULE__{port: port} = state) do
    state =
      state
      |> clear_timeout()
      |> flush_queue_to_leasee()

    maybe_notify_exit(state, 0)
    {:stop, :normal, %{state | status: :closed, port: nil}}
  end

  def handle_info(:transport_timeout, %__MODULE__{port: nil} = state) do
    {:noreply, %{state | timeout_ref: nil}}
  end

  def handle_info(:transport_timeout, %__MODULE__{port: port, timeout_ms: timeout_ms} = state) do
    if is_pid(state.leasee), do: Transport.notify_error(state.leasee, {:timeout, timeout_ms})

    Port.close(port)
    {:noreply, %{state | timeout_ref: nil, status: :closed}}
  rescue
    _ ->
      {:noreply, %{state | timeout_ref: nil, status: :closed}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %__MODULE__{leasee_ref: ref} = state) do
    {:noreply, %{state | leasee: nil, leasee_ref: nil, pending_demand: 0}}
  end

  def handle_info(_message, state) do
    {:noreply, state}
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

  defp maybe_notify_exit(%__MODULE__{leasee: leasee, diagnostics: diagnostics}, status)
       when is_pid(leasee) do
    Transport.notify_exit(leasee, status, diagnostics)
  end

  defp maybe_notify_exit(_state, _status), do: :ok

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

  defp json_object_candidate?(line) do
    trimmed = String.trim(line)
    String.starts_with?(trimmed, "{") and String.ends_with?(trimmed, "}")
  end

  defp maybe_start_subprocess(opts, state) do
    case Keyword.get(opts, :program) do
      program when is_binary(program) and program != "" ->
        args = Enum.map(Keyword.get(opts, :args, []), &to_charlist/1)

        port_opts =
          [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stdout,
            :hide,
            args: args
          ]
          |> maybe_put_env(Keyword.get(opts, :env, %{}))
          |> maybe_put_cwd(Keyword.get(opts, :cwd))

        port = Port.open({:spawn_executable, to_charlist(program)}, port_opts)

        %{state | port: port}
        |> schedule_timeout()

      _ ->
        state
    end
  end

  defp schedule_timeout(%__MODULE__{port: nil} = state), do: state

  defp schedule_timeout(%__MODULE__{timeout_ms: timeout_ms} = state) do
    clear_timeout(state)
    |> Map.put(:timeout_ref, Process.send_after(self(), :transport_timeout, timeout_ms))
  end

  defp reset_timeout(%__MODULE__{port: nil} = state), do: state
  defp reset_timeout(state), do: schedule_timeout(state)

  defp clear_timeout(%__MODULE__{timeout_ref: nil} = state), do: state

  defp clear_timeout(%__MODULE__{timeout_ref: ref} = state) do
    Process.cancel_timer(ref, async: true, info: false)
    %{state | timeout_ref: nil}
  end

  defp normalize_input(input, append_newline?) when is_binary(input) do
    if append_newline? and not String.ends_with?(input, "\n"), do: input <> "\n", else: input
  end

  defp normalize_input(input, append_newline?) do
    input
    |> to_string()
    |> normalize_input(append_newline?)
  end

  defp queue_drop_oldest(queue) do
    case :queue.out(queue) do
      {{:value, item}, remaining} -> {item, remaining}
      {:empty, remaining} -> {nil, remaining}
    end
  end

  defp maybe_put_env(opts, env) when is_map(env) and map_size(env) > 0 do
    env_pairs =
      Enum.map(env, fn {key, value} ->
        {to_charlist(to_string(key)), to_charlist(to_string(value))}
      end)

    [{:env, env_pairs} | opts]
  end

  defp maybe_put_env(opts, _env), do: opts

  defp maybe_put_cwd(opts, cwd) when is_binary(cwd) and cwd != "" do
    [{:cd, to_charlist(cwd)} | opts]
  end

  defp maybe_put_cwd(opts, _cwd), do: opts

  defp normalize_queue_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_queue_limit(_), do: 1_000

  defp normalize_overflow_policy(policy) when policy in [:fail_run, :drop_oldest, :block],
    do: policy

  defp normalize_overflow_policy(_), do: :fail_run

  defp normalize_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_timeout(_), do: @default_timeout_ms

  defp app_default(key, default) do
    Application.get_env(:agent_session_manager, key, default)
  end

  defp transport_error(message) do
    Error.new(:transport_error, :transport, message)
  end
end
