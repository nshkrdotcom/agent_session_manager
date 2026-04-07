defmodule ASM.Store do
  @moduledoc """
  Persistence contract for event storage and replay.
  """

  alias ASM.{Error, Event}

  @callback append_event(pid(), Event.t()) :: :ok | {:error, Error.t()}
  @callback list_events(pid(), String.t()) :: {:ok, [Event.t()]} | {:error, Error.t()}
  @callback reset_session(pid(), String.t()) :: :ok | {:error, Error.t()}

  @spec append_event(pid(), Event.t()) :: :ok | {:error, Error.t()}
  def append_event(store, %Event{} = event), do: GenServer.call(store, {:append_event, event})

  @spec list_events(pid(), String.t()) :: {:ok, [Event.t()]} | {:error, Error.t()}
  def list_events(store, session_id) when is_binary(session_id),
    do: GenServer.call(store, {:list_events, session_id})

  @spec reset_session(pid(), String.t()) :: :ok | {:error, Error.t()}
  def reset_session(store, session_id) when is_binary(session_id),
    do: GenServer.call(store, {:reset_session, session_id})
end
