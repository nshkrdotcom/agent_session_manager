defmodule ASM.Store.Memory do
  @moduledoc """
  In-memory event store with idempotent append by event id.
  """

  use GenServer

  alias ASM.{Error, Event, Store}

  @behaviour Store

  @enforce_keys []
  defstruct by_session: %{}, seen_event_ids: MapSet.new()

  @type t :: %__MODULE__{
          by_session: %{optional(String.t()) => [Event.t()]},
          seen_event_ids: MapSet.t(String.t())
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def append_event(store, event), do: Store.append_event(store, event)

  @impl true
  def list_events(store, session_id), do: Store.list_events(store, session_id)

  @impl true
  def reset_session(store, session_id), do: Store.reset_session(store, session_id)

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:append_event, %Event{} = event}, _from, state) do
    if MapSet.member?(state.seen_event_ids, event.id) do
      {:reply, :ok, state}
    else
      updated_events =
        state.by_session
        |> Map.get(event.session_id, [])
        |> Kernel.++([event])

      next_state = %{
        state
        | by_session: Map.put(state.by_session, event.session_id, updated_events),
          seen_event_ids: MapSet.put(state.seen_event_ids, event.id)
      }

      {:reply, :ok, next_state}
    end
  end

  def handle_call({:list_events, session_id}, _from, state) do
    {:reply, {:ok, Map.get(state.by_session, session_id, [])}, state}
  end

  def handle_call({:reset_session, session_id}, _from, state) do
    session_events = Map.get(state.by_session, session_id, [])

    seen_event_ids =
      Enum.reduce(session_events, state.seen_event_ids, fn event, acc ->
        MapSet.delete(acc, event.id)
      end)

    next_state = %{
      state
      | by_session: Map.delete(state.by_session, session_id),
        seen_event_ids: seen_event_ids
    }

    {:reply, :ok, next_state}
  end

  def handle_call(_other, _from, state) do
    {:reply, {:error, Error.new(:config_invalid, :config, "unsupported store operation")}, state}
  end
end
