defmodule ASM.Load.SessionSoakTest do
  use ExUnit.Case, async: false

  alias ASM.Session.Server

  test "session handles repeated sequential runs without queue growth" do
    session_id = "soak-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    Enum.each(1..40, fn index ->
      assert {:ok, result} =
               ASM.query(session, "run-#{index}", driver: ASM.TestSupport.StreamScriptedDriver)

      assert result.text == "hello from scripted driver"
    end)

    state = Server.get_state(session)
    assert map_size(state.active_runs) == 0
    assert :queue.len(state.run_queue) == 0
    assert state.pending_approval_index == %{}

    assert :ok = ASM.stop_session(session)
  end
end
