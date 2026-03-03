defmodule ASM.Run.ApprovalFlowTest do
  use ExUnit.Case, async: true

  alias ASM.{Control, Event, Run}

  test "approval request registers with session and auto-denies on timeout" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-approval-timeout",
               session_id: "session-approval-timeout",
               provider: :claude,
               session_pid: self(),
               subscriber: self(),
               approval_timeout_ms: 20
             )

    assert_receive {:asm_run_event, "run-approval-timeout", %Event{kind: :run_started}}

    approval_id = "approval-timeout-1"

    assert :ok =
             Run.Server.ingest_event(
               run_pid,
               %Event{
                 id: Event.generate_id(),
                 kind: :approval_requested,
                 run_id: "run-approval-timeout",
                 session_id: "session-approval-timeout",
                 payload: %Control.ApprovalRequest{
                   approval_id: approval_id,
                   tool_name: "bash",
                   tool_input: %{"cmd" => "ls"}
                 },
                 timestamp: DateTime.utc_now()
               }
             )

    assert_receive {:register_approval, ^approval_id, ^run_pid}
    assert_receive {:asm_run_event, "run-approval-timeout", %Event{kind: :approval_requested}}
    assert_receive {:clear_approval, ^approval_id}
    assert_receive {:asm_run_event, "run-approval-timeout", %Event{kind: :approval_resolved}}
  end

  test "explicit approval resolution clears timer and does not auto-timeout" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-approval-manual",
               session_id: "session-approval-manual",
               provider: :claude,
               session_pid: self(),
               subscriber: self(),
               approval_timeout_ms: 200
             )

    assert_receive {:asm_run_event, "run-approval-manual", %Event{kind: :run_started}}

    approval_id = "approval-manual-1"

    assert :ok =
             Run.Server.ingest_event(
               run_pid,
               %Event{
                 id: Event.generate_id(),
                 kind: :approval_requested,
                 run_id: "run-approval-manual",
                 session_id: "session-approval-manual",
                 payload: %Control.ApprovalRequest{
                   approval_id: approval_id,
                   tool_name: "bash",
                   tool_input: %{"cmd" => "pwd"}
                 },
                 timestamp: DateTime.utc_now()
               }
             )

    assert_receive {:register_approval, ^approval_id, ^run_pid}

    assert :ok = Run.Server.resolve_approval(run_pid, approval_id, :allow)
    assert_receive {:clear_approval, ^approval_id}

    assert_receive {:asm_run_event, "run-approval-manual",
                    %Event{
                      kind: :approval_resolved,
                      payload: %Control.ApprovalResolution{decision: :allow}
                    }}

    refute_receive {:asm_run_event, "run-approval-manual",
                    %Event{
                      kind: :approval_resolved,
                      payload: %Control.ApprovalResolution{decision: :deny}
                    }},
                   80
  end

  test "stale approval resolution is ignored safely" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-approval-stale",
               session_id: "session-approval-stale",
               provider: :claude,
               subscriber: self()
             )

    assert :ok = Run.Server.resolve_approval(run_pid, "unknown-approval", :allow)
    assert Process.alive?(run_pid)
    GenServer.stop(run_pid)
  end
end
