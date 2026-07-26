defmodule ASM.RunDeadlineTest do
  use ASM.TestCase

  alias ASM.Run.State
  alias ASM.TestSupport.FakeBackend
  alias CliSubprocessCore.Payload.RunStarted

  @chatty_script [
    {:core, :run_started, RunStarted.new(command: "fake")},
    {:chatter, 5}
  ]

  test "a run that emits events forever still dies at the total deadline" do
    session_id = "run-deadline-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)
    on_exit(fn -> _ = ASM.stop_session(session) end)

    started_at = System.monotonic_time(:millisecond)

    assert {:error, %ASM.Error{} = error} =
             ASM.query(session, "hello",
               backend_module: FakeBackend,
               backend_opts: [script: @chatty_script],
               metadata: %{test_pid: self()},
               run_deadline_ms: 250,
               # Deliberately far larger than the deadline: the per-event
               # stream timeout re-arms on every chatter tick and can never
               # end this run.
               stream_timeout_ms: 30_000
             )

    elapsed_ms = System.monotonic_time(:millisecond) - started_at

    assert error.kind == :timeout
    assert error.domain == :runtime
    assert error.message =~ "deadline"
    assert elapsed_ms < 10_000
  end

  test "the deadline closes the backend session, not just the caller's wait" do
    session_id = "run-deadline-close-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)
    on_exit(fn -> _ = ASM.stop_session(session) end)

    assert {:error, %ASM.Error{kind: :timeout}} =
             ASM.query(session, "hello",
               backend_module: FakeBackend,
               backend_opts: [script: @chatty_script],
               metadata: %{test_pid: self()},
               run_deadline_ms: 250,
               stream_timeout_ms: 30_000
             )

    assert_received {:fake_backend_started, backend_pid}
    assert wait_for_death(backend_pid), "backend session survived the run deadline"
  end

  test "a run that completes before the deadline is unaffected" do
    session_id = "run-deadline-ok-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)
    on_exit(fn -> _ = ASM.stop_session(session) end)

    assert {:ok, result} =
             ASM.query(session, "hello",
               backend_module: FakeBackend,
               backend_opts: [echo_input: true],
               run_deadline_ms: 30_000
             )

    assert result.text == "hello"
  end

  test "the deadline is armed from a documented default" do
    state = State.new(run_id: "run-default", session_id: "s", provider: :claude)

    assert state.run_deadline_ms == 600_000
  end

  test "an explicit :infinity deadline opts out" do
    state =
      State.new(
        run_id: "run-infinite",
        session_id: "s",
        provider: :claude,
        run_deadline_ms: :infinity
      )

    assert state.run_deadline_ms == :infinity
  end

  test "an invalid deadline is refused loudly instead of silently defaulted" do
    assert_raise ArgumentError, ~r/:run_deadline_ms/, fn ->
      State.new(
        run_id: "run-bad",
        session_id: "s",
        provider: :claude,
        run_deadline_ms: 0
      )
    end
  end

  defp wait_for_death(pid, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_for_death(pid, deadline)
  end

  defp do_wait_for_death(pid, deadline) do
    cond do
      not Process.alive?(pid) -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> do_wait_for_death(pid, deadline)
    end
  end
end
