defmodule ASM.InferenceEndpoint.RuntimeConfig do
  @moduledoc """
  Supervised runtime override owner for inference endpoint tests and examples.
  """

  use GenServer

  @name __MODULE__
  @empty_state []

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts) do
    GenServer.start_link(__MODULE__, @empty_state, name: @name)
  end

  @spec current() :: keyword()
  def current do
    case Process.whereis(@name) do
      nil -> @empty_state
      _pid -> GenServer.call(@name, :current)
    end
  end

  @spec configure!(keyword()) :: :ok
  def configure!(opts) when is_list(opts) do
    case Process.whereis(@name) do
      nil -> raise ArgumentError, "ASM inference endpoint runtime config is not started"
      _pid -> GenServer.call(@name, {:configure, opts})
    end
  end

  @spec reset() :: :ok | {:error, :not_started}
  def reset do
    case Process.whereis(@name) do
      nil -> {:error, :not_started}
      _pid -> GenServer.call(@name, :reset)
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state, state}

  def handle_call({:configure, opts}, _from, _state), do: {:reply, :ok, opts}

  def handle_call(:reset, _from, _state), do: {:reply, :ok, @empty_state}
end
