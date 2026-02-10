defmodule AgentSessionManager.Adapters.SessionStoreBridgeTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.{InMemorySessionStore, SessionStoreBridge}
  alias AgentSessionManager.Core.{Event, Run, Session}
  alias AgentSessionManager.Ports.SessionStore

  setup do
    {:ok, store} = InMemorySessionStore.start_link()
    cleanup_on_exit(fn -> safe_stop(store) end)
    %{store: store}
  end

  test "flush/2 persists session, run, and events", %{store: store} do
    {:ok, session} = Session.new(%{agent_id: "bridge-agent", metadata: %{provider: "mock"}})
    {:ok, run} = Run.new(%{session_id: session.id, input: %{prompt: "hello"}})
    {:ok, run} = Run.set_output(run, %{content: "done"})

    {:ok, event} =
      Event.new(%{
        type: :run_started,
        session_id: session.id,
        run_id: run.id,
        data: %{model: "mock"}
      })

    :ok =
      SessionStoreBridge.flush(store, %{
        session: session,
        run: run,
        events: [event],
        provider_metadata: %{model: "mock"}
      })

    assert {:ok, _} = SessionStore.get_session(store, session.id)
    assert {:ok, _} = SessionStore.get_run(store, run.id)
    assert {:ok, [persisted_event]} = SessionStore.get_events(store, session.id, run_id: run.id)
    assert persisted_event.type == :run_started
    assert is_integer(persisted_event.sequence_number)
  end

  test "load delegates to SessionStore", %{store: store} do
    {:ok, session} = Session.new(%{agent_id: "bridge-agent", metadata: %{provider: "mock"}})
    :ok = SessionStore.save_session(store, session)

    {:ok, run} = Run.new(%{session_id: session.id, input: %{prompt: "hello"}})
    :ok = SessionStore.save_run(store, run)

    {:ok, event} =
      Event.new(%{type: :run_started, session_id: session.id, run_id: run.id, data: %{}})

    {:ok, _} = SessionStore.append_event_with_sequence(store, event)

    assert {:ok, loaded_session} = SessionStoreBridge.load_session(store, session.id)
    assert loaded_session.id == session.id

    assert {:ok, loaded_run} = SessionStoreBridge.load_run(store, run.id)
    assert loaded_run.id == run.id

    assert {:ok, events} = SessionStoreBridge.load_events(store, session.id, run_id: run.id)
    assert length(events) == 1
  end
end
