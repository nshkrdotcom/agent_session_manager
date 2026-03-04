defmodule ASM.Run.PipelineIntegrationTest do
  use ASM.TestCase

  alias ASM.{Event, Message, Run}

  test "cost tracker pipeline injects cost_update event in run stream" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-pipeline-int",
               session_id: "session-pipeline-int",
               provider: :claude,
               subscriber: self(),
               pipeline: [{ASM.Pipeline.CostTracker, input_rate: 0.1, output_rate: 0.2}]
             )

    assert_receive {:asm_run_event, "run-pipeline-int", %Event{kind: :run_started}}

    result_event =
      %Event{
        id: Event.generate_id(),
        kind: :result,
        run_id: "run-pipeline-int",
        session_id: "session-pipeline-int",
        provider: :claude,
        payload: %Message.Result{
          stop_reason: :end_turn,
          usage: %{input_tokens: 2, output_tokens: 3}
        },
        timestamp: DateTime.utc_now()
      }

    assert :ok = Run.Server.ingest_event(run_pid, result_event)
    assert_receive {:asm_run_event, "run-pipeline-int", %Event{kind: :result}}
    assert_receive {:asm_run_event, "run-pipeline-int", %Event{kind: :cost_update}}
    assert_receive {:asm_run_done, "run-pipeline-int"}
  end

  test "policy guard pipeline blocks tool event and emits error" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-pipeline-guard",
               session_id: "session-pipeline-guard",
               provider: :claude,
               subscriber: self(),
               pipeline: [{ASM.Pipeline.PolicyGuard, disallow_tools: ["bash"]}]
             )

    assert_receive {:asm_run_event, "run-pipeline-guard", %Event{kind: :run_started}}

    tool_event =
      %Event{
        id: Event.generate_id(),
        kind: :tool_use,
        run_id: "run-pipeline-guard",
        session_id: "session-pipeline-guard",
        provider: :claude,
        payload: %Message.ToolUse{
          tool_name: "bash",
          tool_id: "tool-guard-1",
          input: %{"cmd" => "ls"}
        },
        timestamp: DateTime.utc_now()
      }

    assert :ok = Run.Server.ingest_event(run_pid, tool_event)
    assert_receive {:asm_run_event, "run-pipeline-guard", %Event{kind: :error}}
    refute_receive {:asm_run_event, "run-pipeline-guard", %Event{kind: :tool_use}}, 20
  end
end
