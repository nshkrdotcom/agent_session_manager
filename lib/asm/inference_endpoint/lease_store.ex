defmodule ASM.InferenceEndpoint.LeaseStore do
  @moduledoc false

  use GenServer

  @type lease :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, Keyword.put(opts, :name, __MODULE__))
  end

  @spec put(lease()) :: :ok
  def put(%{} = lease), do: GenServer.call(__MODULE__, {:put, lease})

  @spec fetch(String.t()) :: {:ok, lease()} | :error
  def fetch(lease_ref) when is_binary(lease_ref),
    do: GenServer.call(__MODULE__, {:fetch, lease_ref})

  @spec delete(String.t()) :: :ok
  def delete(lease_ref) when is_binary(lease_ref),
    do: GenServer.call(__MODULE__, {:delete, lease_ref})

  @spec list() :: [lease()]
  def list, do: GenServer.call(__MODULE__, :list)

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:put, %{} = lease}, _from, state) do
    {:reply, :ok, Map.put(state, lease.lease_ref, lease)}
  end

  def handle_call({:fetch, lease_ref}, _from, state) do
    {:reply, Map.fetch(state, lease_ref), state}
  end

  def handle_call({:delete, lease_ref}, _from, state) do
    {:reply, :ok, Map.delete(state, lease_ref)}
  end

  def handle_call(:list, _from, state) do
    {:reply, Map.values(state), state}
  end
end
