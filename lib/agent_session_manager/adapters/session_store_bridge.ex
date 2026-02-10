defmodule AgentSessionManager.Adapters.SessionStoreBridge do
  @moduledoc """
  `DurableStore` adapter backed by an existing `SessionStore`.
  """

  @behaviour AgentSessionManager.Ports.DurableStore

  alias AgentSessionManager.Core.{Error, Event, Run, Session}
  alias AgentSessionManager.Ports.SessionStore

  @impl AgentSessionManager.Ports.DurableStore
  @spec flush(SessionStore.store(), map()) :: :ok | {:error, Error.t()}
  def flush(store, %{session: %Session{} = session, run: %Run{} = run, events: events})
      when is_list(events) do
    with :ok <- SessionStore.save_session(store, session),
         :ok <- SessionStore.save_run(store, run) do
      persist_events(store, events)
    end
  end

  @impl AgentSessionManager.Ports.DurableStore
  @spec load_run(SessionStore.store(), String.t()) :: {:ok, Run.t()} | {:error, Error.t()}
  def load_run(store, run_id) do
    SessionStore.get_run(store, run_id)
  end

  @impl AgentSessionManager.Ports.DurableStore
  @spec load_session(SessionStore.store(), String.t()) :: {:ok, Session.t()} | {:error, Error.t()}
  def load_session(store, session_id) do
    SessionStore.get_session(store, session_id)
  end

  @impl AgentSessionManager.Ports.DurableStore
  @spec load_events(SessionStore.store(), String.t(), keyword()) ::
          {:ok, [Event.t()]} | {:error, Error.t()}
  def load_events(store, session_id, opts \\ []) do
    SessionStore.get_events(store, session_id, opts)
  end

  defp persist_events(store, events) do
    Enum.reduce_while(events, :ok, fn
      %Event{} = event, :ok ->
        case SessionStore.append_event_with_sequence(store, event) do
          {:ok, _stored} -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end

      _other, :ok ->
        {:halt, {:error, Error.new(:validation_error, "flush events must be Event structs")}}
    end)
  end
end
