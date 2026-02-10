defmodule AgentSessionManager.Test.RunScopedEventBlindStore do
  @moduledoc false

  use GenServer

  alias AgentSessionManager.Adapters.InMemorySessionStore

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, store} = InMemorySessionStore.start_link()
    {:ok, %{store: store}}
  end

  @impl GenServer
  def handle_call({:get_events, session_id, opts}, _from, state) do
    if Keyword.has_key?(opts, :run_id) do
      {:reply, {:ok, []}, state}
    else
      reply = GenServer.call(state.store, {:get_events, session_id, opts})
      {:reply, reply, state}
    end
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
