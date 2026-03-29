defmodule ASM.ProviderBackend.Proxy do
  @moduledoc false

  use GenServer

  alias ASM.ProviderBackend.{Event, Info}
  alias CliSubprocessCore.Event, as: CoreEvent

  @proxy_start_timeout_ms 5_000

  defstruct [
    :runtime_api,
    :runtime,
    :provider,
    :lane,
    :backend,
    :session,
    :session_ref,
    :upstream_subscription_ref,
    :raw_session_event_tag,
    :info,
    capabilities: [],
    subscribers: %{}
  ]

  @type t :: %__MODULE__{
          runtime_api: module(),
          runtime: module(),
          provider: atom(),
          lane: atom(),
          backend: module(),
          session: pid(),
          session_ref: reference(),
          upstream_subscription_ref: reference(),
          raw_session_event_tag: atom(),
          info: Info.t(),
          capabilities: [atom()],
          subscribers: %{optional(reference()) => pid()}
        }

  @spec start_link(keyword()) :: {:ok, pid(), Info.t()} | {:error, term()}
  def start_link(opts) when is_list(opts) do
    caller = self()
    reply_ref = make_ref()

    with_trap_exit(fn ->
      case GenServer.start_link(__MODULE__, {caller, reply_ref, opts}) do
        {:ok, pid} ->
          await_started_proxy(pid, reply_ref)

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  @spec send_input(pid(), iodata(), keyword()) :: :ok | {:error, term()}
  def send_input(proxy, input, opts \\ []) when is_pid(proxy) do
    GenServer.call(proxy, {:send_input, input, opts})
  end

  @spec end_input(pid()) :: :ok | {:error, term()}
  def end_input(proxy) when is_pid(proxy), do: GenServer.call(proxy, :end_input)

  @spec interrupt(pid()) :: :ok | {:error, term()}
  def interrupt(proxy) when is_pid(proxy), do: GenServer.call(proxy, :interrupt)

  @spec close(pid()) :: :ok
  def close(proxy) when is_pid(proxy) do
    GenServer.stop(proxy, :normal)
  catch
    :exit, _reason -> :ok
  end

  @spec subscribe(pid(), pid(), reference()) :: :ok | {:error, term()}
  def subscribe(proxy, pid, ref) when is_pid(proxy) and is_pid(pid) and is_reference(ref) do
    GenServer.call(proxy, {:subscribe, pid, ref})
  end

  @spec info(pid()) :: Info.t()
  def info(proxy) when is_pid(proxy), do: GenServer.call(proxy, :info)

  @impl true
  def init({caller, reply_ref, opts}) do
    starter = Keyword.fetch!(opts, :starter)
    runtime_api = Keyword.fetch!(opts, :runtime_api)
    runtime = Keyword.get(opts, :runtime, runtime_api)
    provider = Keyword.fetch!(opts, :provider)
    lane = Keyword.fetch!(opts, :lane)
    backend = Keyword.fetch!(opts, :backend)
    capabilities = Keyword.get(opts, :capabilities, [])
    upstream_subscription_ref = make_ref()
    initial_subscribers = normalize_subscribers(Keyword.get(opts, :initial_subscribers, %{}))

    case start_backend_session(starter, {self(), upstream_subscription_ref}) do
      {:ok, session, raw_info} when is_pid(session) ->
        raw_session_event_tag =
          Info.session_event_tag(raw_info, runtime_session_event_tag(runtime_api))

        info =
          build_info(provider, lane, backend, runtime, session, capabilities, raw_info)

        send(caller, {:asm_backend_proxy_started, reply_ref, info})

        {:ok,
         %__MODULE__{
           runtime_api: runtime_api,
           runtime: runtime,
           provider: provider,
           lane: lane,
           backend: backend,
           session: session,
           session_ref: Process.monitor(session),
           upstream_subscription_ref: upstream_subscription_ref,
           raw_session_event_tag: raw_session_event_tag,
           info: info,
           capabilities: capabilities,
           subscribers: initial_subscribers
         }}

      {:ok, _session, _raw_info} ->
        {:stop, :invalid_backend_session}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send_input, input, opts}, _from, %__MODULE__{} = state) do
    {:reply, state.runtime_api.send_input(state.session, input, opts), state}
  end

  def handle_call(:end_input, _from, %__MODULE__{} = state) do
    {:reply, state.runtime_api.end_input(state.session), state}
  end

  def handle_call(:interrupt, _from, %__MODULE__{} = state) do
    {:reply, state.runtime_api.interrupt(state.session), state}
  end

  def handle_call({:subscribe, pid, ref}, _from, %__MODULE__{} = state) do
    {:reply, :ok, put_in(state.subscribers[ref], pid)}
  end

  def handle_call(:info, _from, %__MODULE__{} = state) do
    info =
      case refresh_runtime_info(state) do
        {:ok, info} -> info
        :error -> state.info
      end

    {:reply, info, %{state | info: info}}
  end

  @impl true
  def handle_info(
        {event_tag, ref, {:event, %CoreEvent{} = core_event}},
        %{raw_session_event_tag: event_tag, upstream_subscription_ref: ref} = state
      ) do
    {:noreply, forward_event(state, core_event)}
  end

  def handle_info(
        {event_tag, ref, %CoreEvent{} = core_event},
        %{raw_session_event_tag: event_tag, upstream_subscription_ref: ref} = state
      ) do
    {:noreply, forward_event(state, core_event)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %__MODULE__{session_ref: ref} = state) do
    {:stop, reason, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %__MODULE__{} = state) do
    _ = state.runtime_api.close(state.session)
    :ok
  end

  defp forward_event(%__MODULE__{} = state, %CoreEvent{} = core_event) do
    Enum.each(state.subscribers, fn
      {ref, pid} when is_reference(ref) and is_pid(pid) ->
        send(pid, Event.new(ref, core_event))

      _other ->
        :ok
    end)

    state
  end

  defp build_info(provider, lane, backend, runtime, session, capabilities, raw_info) do
    Info.new(
      provider: provider,
      lane: lane,
      backend: backend,
      runtime: runtime,
      capabilities: capabilities,
      session_pid: session,
      raw_info: raw_info
    )
  end

  defp refresh_runtime_info(%__MODULE__{} = state) do
    info =
      state.runtime_api.info(state.session)
      |> build_info_from_raw(
        state.provider,
        state.lane,
        state.backend,
        state.runtime,
        state.session,
        state.capabilities
      )

    {:ok, info}
  rescue
    _error ->
      :error
  catch
    :exit, _reason ->
      :error
  end

  defp build_info_from_raw(raw_info, provider, lane, backend, runtime, session, capabilities) do
    build_info(provider, lane, backend, runtime, session, capabilities, raw_info)
  end

  defp runtime_session_event_tag(runtime_api) when is_atom(runtime_api) do
    runtime_api.session_event_tag()
  rescue
    UndefinedFunctionError -> nil
  end

  defp start_backend_session(starter, subscriber) when is_function(starter, 1) do
    starter.(subscriber)
  end

  defp start_backend_session(starter, _subscriber) when is_function(starter, 0) do
    starter.()
  end

  defp normalize_subscribers(%{} = subscribers) do
    Enum.reduce(subscribers, %{}, fn
      {ref, pid}, acc when is_reference(ref) and is_pid(pid) -> Map.put(acc, ref, pid)
      {_key, _value}, acc -> acc
    end)
  end

  defp normalize_subscribers(_subscribers), do: %{}

  defp await_started_proxy(pid, reply_ref, timeout_ms \\ @proxy_start_timeout_ms) do
    receive do
      {:asm_backend_proxy_started, ^reply_ref, info} ->
        {:ok, pid, info}

      {:EXIT, ^pid, reason} ->
        {:error, reason}
    after
      timeout_ms ->
        safe_stop_proxy(pid)
        {:error, :backend_proxy_start_timeout}
    end
  end

  defp safe_stop_proxy(pid) when is_pid(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _reason -> :ok
  end

  defp with_trap_exit(fun) when is_function(fun, 0) do
    previous_trap_exit? = Process.flag(:trap_exit, true)

    try do
      fun.()
    after
      Process.flag(:trap_exit, previous_trap_exit?)
    end
  end
end
