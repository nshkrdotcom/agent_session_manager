defmodule ASM.TestSupport.FakeBackend do
  @moduledoc false

  use GenServer

  @behaviour ASM.ProviderBackend

  alias ASM.ProviderBackend.{Event, Info}
  alias CliSubprocessCore.Event, as: CoreEvent
  alias CliSubprocessCore.Payload

  defstruct [:config, :subscriber, :subscription_ref, :emitted?]

  @spec start_run(map()) :: {:ok, pid(), Info.t()} | {:error, term()}
  @impl true
  def start_run(config) when is_map(config) do
    with {:ok, pid} <- GenServer.start_link(__MODULE__, config) do
      {:ok, pid,
       Info.new(
         provider: config.provider.name,
         lane: Map.get(config, :lane, :core),
         backend: __MODULE__,
         runtime: __MODULE__,
         capabilities: [],
         session_pid: pid,
         raw_info: %{backend: :fake, provider: config.provider.name}
       )}
    end
  end

  @spec send_input(pid(), iodata(), keyword()) :: :ok | {:error, term()}
  @impl true
  def send_input(server, input, _opts \\ []) do
    GenServer.call(server, {:send_input, IO.iodata_to_binary(input)})
  end

  @spec end_input(pid()) :: :ok | {:error, term()}
  @impl true
  def end_input(_server), do: :ok

  @spec interrupt(pid()) :: :ok | {:error, term()}
  @impl true
  def interrupt(server) do
    GenServer.call(server, :interrupt)
  end

  @spec close(pid()) :: :ok
  @impl true
  def close(server) do
    GenServer.stop(server, :normal)
  catch
    :exit, _ -> :ok
  end

  @spec subscribe(pid(), pid(), reference()) :: :ok | {:error, term()}
  @impl true
  def subscribe(server, pid, ref) do
    GenServer.call(server, {:subscribe, pid, ref})
  end

  @spec info(pid()) :: Info.t()
  @impl true
  def info(server) do
    GenServer.call(server, :info)
  end

  @impl true
  def init(config) do
    state = %__MODULE__{
      config: config,
      subscriber: Map.get(config, :subscriber_pid),
      subscription_ref: Map.get(config, :subscription_ref),
      emitted?: false
    }

    {:ok, state, {:continue, :emit_initial_events}}
  end

  @impl true
  def handle_continue(:emit_initial_events, state) do
    state = emit_script(state, Keyword.get(state.config.backend_opts, :script))
    {:noreply, state}
  end

  @impl true
  def handle_call({:send_input, input}, _from, state) do
    reply =
      if Keyword.get(state.config.backend_opts, :echo_input, false) do
        emit_core_event(state, :assistant_delta, Payload.AssistantDelta.new(content: input))

        emit_core_event(
          state,
          :result,
          Payload.Result.new(status: :completed, stop_reason: :end_turn)
        )
      end

    {:reply, :ok, %{state | emitted?: state.emitted? or reply == :ok}}
  end

  def handle_call(:interrupt, _from, state) do
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, pid, ref}, _from, state) do
    {:reply, :ok, %{state | subscriber: pid, subscription_ref: ref}}
  end

  def handle_call(:info, _from, state) do
    info =
      Info.new(
        provider: state.config.provider.name,
        lane: Map.get(state.config, :lane, :core),
        backend: __MODULE__,
        runtime: __MODULE__,
        capabilities: [],
        session_pid: self(),
        raw_info: %{backend: :fake, provider: state.config.provider.name}
      )

    {:reply, info, state}
  end

  defp emit_script(state, nil) do
    emit_core_event(
      state,
      :run_started,
      Payload.RunStarted.new(command: "fake", args: [state.config.prompt], cwd: "/tmp")
    )

    emit_core_event(
      state,
      :assistant_delta,
      Payload.AssistantDelta.new(content: default_text(state))
    )

    emit_core_event(
      state,
      :result,
      Payload.Result.new(status: :completed, stop_reason: :end_turn)
    )

    %{state | emitted?: true}
  end

  defp emit_script(state, script) when is_list(script) do
    Enum.each(script, fn
      {:core, kind, payload} ->
        emit_core_event(state, kind, payload)

      {:send, message} ->
        send(self(), message)
    end)

    %{state | emitted?: true}
  end

  defp default_text(state) do
    Keyword.get(state.config.provider_opts, :model, state.config.prompt)
  end

  defp emit_core_event(%__MODULE__{} = state, kind, payload) do
    if is_pid(state.subscriber) and is_reference(state.subscription_ref) do
      event =
        CoreEvent.new(kind,
          provider: state.config.provider.name,
          payload: payload
        )

      send(
        state.subscriber,
        Event.new(state.subscription_ref, event)
      )

      :ok
    else
      {:error, :no_subscriber}
    end
  end
end
