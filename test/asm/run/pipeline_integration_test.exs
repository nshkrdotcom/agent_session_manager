defmodule ASM.Run.PipelineIntegrationTest do
  use ASM.TestCase

  alias ASM.{Control, Event, Message, Run}
  alias ASM.Extensions.Policy

  @receive_timeout 500

  test "cost tracker pipeline injects cost_update event in run stream" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-pipeline-int",
               session_id: "session-pipeline-int",
               provider: :claude,
               subscriber: self(),
               pipeline: [{ASM.Pipeline.CostTracker, input_rate: 0.1, output_rate: 0.2}]
             )

    assert_receive {:asm_run_event, "run-pipeline-int", %Event{kind: :run_started}},
                   @receive_timeout

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

    assert_receive {:asm_run_event, "run-pipeline-guard", %Event{kind: :run_started}},
                   @receive_timeout

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

  test "policy enforcer with request_approval action emits approval request and blocks tool execution" do
    policy = Policy.new!(disallow_tools: ["bash"], on_tool_violation: :request_approval)

    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-pipeline-policy-approval",
               session_id: "session-pipeline-policy-approval",
               provider: :claude,
               subscriber: self(),
               session_pid: self(),
               pipeline: [
                 {ASM.Extensions.Policy.Enforcer,
                  [
                    policy: policy,
                    approval_id_fun: fn _event, _violation -> "approval-pipeline-policy-1" end
                  ]}
               ]
             )

    on_exit(fn -> if Process.alive?(run_pid), do: GenServer.stop(run_pid) end)

    assert_receive {:asm_run_event, "run-pipeline-policy-approval", %Event{kind: :run_started}},
                   @receive_timeout

    tool_event =
      %Event{
        id: Event.generate_id(),
        kind: :tool_use,
        run_id: "run-pipeline-policy-approval",
        session_id: "session-pipeline-policy-approval",
        provider: :claude,
        payload: %Message.ToolUse{
          tool_name: "bash",
          tool_id: "tool-policy-approval-1",
          input: %{"cmd" => "pwd"}
        },
        timestamp: DateTime.utc_now()
      }

    assert :ok = Run.Server.ingest_event(run_pid, tool_event)
    assert_receive {:register_approval, "approval-pipeline-policy-1", ^run_pid}

    assert_receive {:asm_run_event, "run-pipeline-policy-approval",
                    %Event{
                      kind: :approval_requested,
                      payload: %Control.ApprovalRequest{
                        approval_id: "approval-pipeline-policy-1",
                        tool_name: "bash",
                        tool_input: %{"cmd" => "pwd"}
                      }
                    }}

    assert_receive {:asm_run_event, "run-pipeline-policy-approval",
                    %Event{
                      kind: :guardrail_triggered,
                      payload: %Control.GuardrailTrigger{
                        action: :request_approval,
                        rule: "tool_disallowed"
                      }
                    }}

    refute_receive {:asm_run_event, "run-pipeline-policy-approval", %Event{kind: :tool_use}}, 20

    refute_receive {:asm_run_event, "run-pipeline-policy-approval", %Event{kind: :tool_result}},
                   20
  end

  test "policy enforcer with cancel action emits error and blocks tool execution" do
    policy = Policy.new!(disallow_tools: ["bash"], on_tool_violation: :cancel)

    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-pipeline-policy-cancel",
               session_id: "session-pipeline-policy-cancel",
               provider: :claude,
               subscriber: self(),
               pipeline: [{ASM.Extensions.Policy.Enforcer, policy: policy}]
             )

    assert_receive {:asm_run_event, "run-pipeline-policy-cancel", %Event{kind: :run_started}},
                   @receive_timeout

    tool_event =
      %Event{
        id: Event.generate_id(),
        kind: :tool_use,
        run_id: "run-pipeline-policy-cancel",
        session_id: "session-pipeline-policy-cancel",
        provider: :claude,
        payload: %Message.ToolUse{
          tool_name: "bash",
          tool_id: "tool-policy-cancel-1",
          input: %{"cmd" => "pwd"}
        },
        timestamp: DateTime.utc_now()
      }

    assert :ok = Run.Server.ingest_event(run_pid, tool_event)

    assert_receive {:asm_run_event, "run-pipeline-policy-cancel",
                    %Event{
                      kind: :error,
                      payload: %Message.Error{kind: :guardrail_blocked}
                    }}

    refute_receive {:asm_run_event, "run-pipeline-policy-cancel", %Event{kind: :tool_use}}, 20
    refute_receive {:asm_run_event, "run-pipeline-policy-cancel", %Event{kind: :tool_result}}, 20
  end

  test "policy enforcer with warn action emits guardrail event and keeps result event" do
    policy = Policy.new!(max_output_tokens: 0, on_budget_violation: :warn)

    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-pipeline-policy-warn",
               session_id: "session-pipeline-policy-warn",
               provider: :claude,
               subscriber: self(),
               pipeline: [{ASM.Extensions.Policy.Enforcer, policy: policy}]
             )

    assert_receive {:asm_run_event, "run-pipeline-policy-warn", %Event{kind: :run_started}}

    result_event =
      %Event{
        id: Event.generate_id(),
        kind: :result,
        run_id: "run-pipeline-policy-warn",
        session_id: "session-pipeline-policy-warn",
        provider: :claude,
        payload: %Message.Result{
          stop_reason: :end_turn,
          usage: %{input_tokens: 1, output_tokens: 2}
        },
        timestamp: DateTime.utc_now()
      }

    assert :ok = Run.Server.ingest_event(run_pid, result_event)
    assert_receive {:asm_run_event, "run-pipeline-policy-warn", %Event{kind: :result}}

    assert_receive {:asm_run_event, "run-pipeline-policy-warn",
                    %Event{
                      kind: :guardrail_triggered,
                      payload: %Control.GuardrailTrigger{
                        action: :warn,
                        rule: "output_budget_exceeded"
                      }
                    }}

    refute_receive {:asm_run_event, "run-pipeline-policy-warn", %Event{kind: :error}}, 20
    assert_receive {:asm_run_done, "run-pipeline-policy-warn"}
  end
end
