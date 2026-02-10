defmodule AgentSessionManager.Persistence.ExecutionStateTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.{Event, Run, Session}
  alias AgentSessionManager.Persistence.ExecutionState

  defp build_session_run do
    {:ok, session} = Session.new(%{agent_id: "exec-state-agent", metadata: %{provider: "mock"}})
    {:ok, run} = Run.new(%{session_id: session.id, input: %{prompt: "hello"}})
    {:ok, run} = Run.update_status(run, :running)
    {session, run}
  end

  test "new/2 seeds state with session and run" do
    {session, run} = build_session_run()
    state = ExecutionState.new(session, run)

    assert state.session.id == session.id
    assert state.run.id == run.id
    assert state.events == []
    assert state.provider_metadata == %{}
    assert state.sequence_counter == 0
  end

  test "append_event/2 assigns local sequence and preserves order via finalized_events/1" do
    {session, run} = build_session_run()
    state = ExecutionState.new(session, run)

    {:ok, event_1} =
      Event.new(%{type: :run_started, session_id: session.id, run_id: run.id, data: %{}})

    {:ok, event_2} =
      Event.new(%{
        type: :message_received,
        session_id: session.id,
        run_id: run.id,
        data: %{content: "hi", role: "assistant"}
      })

    state =
      state
      |> ExecutionState.append_event(event_1)
      |> ExecutionState.append_event(event_2)

    finalized = ExecutionState.finalized_events(state)

    assert state.sequence_counter == 2
    assert Enum.map(finalized, & &1.sequence_number) == [1, 2]
    assert Enum.map(finalized, & &1.type) == [:run_started, :message_received]
  end

  test "cache_provider_metadata/2 merges metadata maps" do
    {session, run} = build_session_run()

    state =
      session
      |> ExecutionState.new(run)
      |> ExecutionState.cache_provider_metadata(%{model: "mock-model"})
      |> ExecutionState.cache_provider_metadata(%{provider_session_id: "thread_123"})

    assert state.provider_metadata == %{model: "mock-model", provider_session_id: "thread_123"}
  end

  test "to_result/1 returns execution payload" do
    {session, run} = build_session_run()
    state = ExecutionState.new(session, run)
    result = ExecutionState.to_result(state)

    assert result.session.id == session.id
    assert result.run.id == run.id
    assert result.events == []
    assert result.provider_metadata == %{}
  end
end
