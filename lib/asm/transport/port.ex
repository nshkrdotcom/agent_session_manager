defmodule ASM.Transport.Port do
  @moduledoc """
  Lease-aware transport implementation with demand-driven fanout.

  This foundation implementation focuses on contract correctness:
  attach/detach ownership, caller-aware demand, and deterministic queue delivery.
  """

  use GenServer

  alias ASM.Transport

  @behaviour Transport

  @enforce_keys []
  defstruct leasee: nil,
            leasee_ref: nil,
            queue: :queue.new(),
            pending_demand: 0,
            queue_limit: 1_000,
            overflow_policy: :fail_run,
            status: :open

  @type t :: %__MODULE__{
          leasee: pid() | nil,
          leasee_ref: reference() | nil,
          queue: :queue.queue(map()),
          pending_demand: non_neg_integer(),
          queue_limit: pos_integer(),
          overflow_policy: :fail_run | :drop_oldest | :block,
          status: :open | :closed
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

    {:ok,
     %__MODULE__{
       queue_limit: normalize_queue_limit(queue_limit),
       overflow_policy: normalize_overflow_policy(overflow_policy)
     }}
  end

  @impl true
  def handle_call(:health, _from, %__MODULE__{status: :open} = state) do
    {:reply, :healthy, state}
  end

  def handle_call(:health, _from, state) do
    {:reply, :degraded, state}
  end

  def handle_call(:close, _from, state) do
    {:stop, :normal, :ok, %{state | status: :closed}}
  end

  def handle_call({:send_input, _input, _opts}, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call(:interrupt, _from, state) do
    {:reply, :ok, state}
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
    {:stop, :buffer_overflow, %{state | status: :closed}}
  end

  defp queue_drop_oldest(queue) do
    case :queue.out(queue) do
      {{:value, item}, remaining} -> {item, remaining}
      {:empty, remaining} -> {nil, remaining}
    end
  end

  defp normalize_queue_limit(limit) when is_integer(limit) and limit > 0, do: limit
  defp normalize_queue_limit(_), do: 1_000

  defp normalize_overflow_policy(policy) when policy in [:fail_run, :drop_oldest, :block],
    do: policy

  defp normalize_overflow_policy(_), do: :fail_run

  defp app_default(key, default) do
    Application.get_env(:agent_session_manager, key, default)
  end
end
