defmodule AgentSessionManager.Test.FlushTrackingStore do
  @moduledoc false

  use GenServer

  alias AgentSessionManager.Adapters.InMemorySessionStore

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec flush_calls(GenServer.server()) :: [map()]
  def flush_calls(store) do
    GenServer.call(store, :get_flush_calls)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, store} = InMemorySessionStore.start_link([])
    {:ok, %{store: store, flush_calls: []}}
  end

  @impl GenServer
  def handle_call(:get_flush_calls, _from, state) do
    {:reply, Enum.reverse(state.flush_calls), state}
  end

  def handle_call({:flush, execution_result}, _from, state) do
    reply = GenServer.call(state.store, {:flush, execution_result})
    {:reply, reply, %{state | flush_calls: [execution_result | state.flush_calls]}}
  end

  def handle_call(request, _from, state) do
    {:reply, GenServer.call(state.store, request), state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    if Process.alive?(state.store) do
      GenServer.stop(state.store, :normal)
    end

    :ok
  end
end
