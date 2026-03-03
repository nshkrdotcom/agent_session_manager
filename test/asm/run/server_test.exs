defmodule ASM.Run.ServerTest do
  use ExUnit.Case, async: true

  alias ASM.{Event, Message, Run}

  test "emits run_started event on bootstrap" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-boot",
               session_id: "session-boot",
               provider: :claude,
               subscriber: self()
             )

    assert_receive {:asm_run_event, "run-boot", %Event{kind: :run_started}}
    GenServer.stop(run_pid)
  end

  test "ingest_event updates reducer state and terminal event emits done" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-events",
               session_id: "session-events",
               provider: :claude,
               subscriber: self()
             )

    assert_receive {:asm_run_event, "run-events", %Event{kind: :run_started}}

    delta_event =
      %Event{
        id: Event.generate_id(),
        kind: :assistant_delta,
        run_id: "run-events",
        session_id: "session-events",
        payload: %Message.Partial{content_type: :text, delta: "abc"},
        timestamp: DateTime.utc_now()
      }

    assert :ok = Run.Server.ingest_event(run_pid, delta_event)
    assert_receive {:asm_run_event, "run-events", %Event{kind: :assistant_delta}}

    state = Run.Server.get_state(run_pid)
    assert state.text_acc == "abc"

    result_event =
      %Event{
        id: Event.generate_id(),
        kind: :result,
        run_id: "run-events",
        session_id: "session-events",
        payload: %Message.Result{stop_reason: :end_turn},
        timestamp: DateTime.utc_now()
      }

    ref = Process.monitor(run_pid)
    assert :ok = Run.Server.ingest_event(run_pid, result_event)
    assert_receive {:asm_run_event, "run-events", %Event{kind: :result}}
    assert_receive {:asm_run_done, "run-events"}
    assert_receive {:DOWN, ^ref, :process, ^run_pid, :normal}
  end

  test "interrupt emits done and stops run" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-int",
               session_id: "session-int",
               provider: :claude,
               subscriber: self()
             )

    assert_receive {:asm_run_event, "run-int", %Event{kind: :run_started}}

    ref = Process.monitor(run_pid)
    assert :ok = Run.Server.interrupt(run_pid)
    assert_receive {:asm_run_event, "run-int", %Event{kind: :error}}
    assert_receive {:asm_run_done, "run-int"}
    assert_receive {:DOWN, ^ref, :process, ^run_pid, :normal}
  end
end
