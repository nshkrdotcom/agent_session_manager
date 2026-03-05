defmodule ASM.Extensions.Policy.EnforcerTest do
  use ASM.TestCase

  alias ASM.{Control, Event, Message, Pipeline}
  alias ASM.Extensions.Policy
  alias ASM.Extensions.Policy.Enforcer

  test "warn action injects guardrail event and preserves source event" do
    policy = Policy.new!(max_output_tokens: 0, on_budget_violation: :warn)
    event = result_event(2)

    assert {:ok, [primary, guardrail], ctx} =
             Pipeline.run(event, [{Enforcer, policy: policy}], %{})

    assert primary.kind == :result
    assert guardrail.kind == :guardrail_triggered

    assert %Control.GuardrailTrigger{action: :warn, rule: "output_budget_exceeded"} =
             guardrail.payload

    assert get_in(ctx, [:policy, :last_violation, :action]) == :warn
  end

  test "request_approval action halts source event and emits approval request" do
    policy = Policy.new!(disallow_tools: ["bash"], on_tool_violation: :request_approval)
    event = tool_event("bash", %{"cmd" => "pwd"})
    fixed_now = ~U[2026-03-04 08:00:00Z]

    assert {:ok, [approval_event, guardrail_event], ctx} =
             Pipeline.run(
               event,
               [
                 {Enforcer,
                  [
                    policy: policy,
                    approval_id_fun: fn _event, _violation -> "approval-ext-policy-1" end,
                    now_fun: fn -> fixed_now end
                  ]}
               ],
               %{}
             )

    assert approval_event.kind == :approval_requested
    assert approval_event.timestamp == fixed_now
    assert approval_event.correlation_id == event.id
    assert approval_event.causation_id == event.id

    assert %Control.ApprovalRequest{
             approval_id: "approval-ext-policy-1",
             tool_name: "bash",
             tool_input: %{"cmd" => "pwd"}
           } = approval_event.payload

    assert guardrail_event.kind == :guardrail_triggered

    assert %Control.GuardrailTrigger{
             action: :request_approval,
             direction: :input,
             rule: "tool_disallowed"
           } = guardrail_event.payload

    assert get_in(ctx, [:policy, :last_violation, :action]) == :request_approval
  end

  test "cancel action returns guardrail error" do
    policy = Policy.new!(disallow_tools: ["bash"], on_tool_violation: :cancel)
    event = tool_event("bash", %{})

    assert {:error, error, ctx} =
             Pipeline.run(event, [{Enforcer, policy: policy}], %{})

    assert error.kind == :guardrail_blocked
    assert error.domain == :guardrail
    assert get_in(ctx, [:policy, :last_violation, :action]) == :cancel
  end

  defp tool_event(tool_name, input) do
    %Event{
      id: Event.generate_id(),
      kind: :tool_use,
      run_id: "run-ext-policy-enforcer",
      session_id: "session-ext-policy-enforcer",
      provider: :claude,
      payload: %Message.ToolUse{
        tool_name: tool_name,
        tool_id: "tool-ext-policy-enforcer-1",
        input: input
      },
      timestamp: DateTime.utc_now()
    }
  end

  defp result_event(output_tokens) do
    %Event{
      id: Event.generate_id(),
      kind: :result,
      run_id: "run-ext-policy-enforcer",
      session_id: "session-ext-policy-enforcer",
      provider: :claude,
      payload: %Message.Result{stop_reason: :end_turn, usage: %{output_tokens: output_tokens}},
      timestamp: DateTime.utc_now()
    }
  end
end
