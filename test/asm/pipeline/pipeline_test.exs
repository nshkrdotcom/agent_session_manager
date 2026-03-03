defmodule ASM.PipelineTest do
  use ExUnit.Case, async: true

  alias ASM.{Control, Event, Message, Pipeline}

  test "cost tracker injects cost_update event from result usage" do
    result_event =
      %Event{
        id: Event.generate_id(),
        kind: :result,
        run_id: "run-pipeline-cost",
        session_id: "session-pipeline-cost",
        provider: :claude,
        payload: %Message.Result{
          stop_reason: :end_turn,
          usage: %{input_tokens: 2, output_tokens: 3}
        },
        timestamp: DateTime.utc_now()
      }

    assert {:ok, [primary, injected], ctx} =
             Pipeline.run(
               result_event,
               [{ASM.Pipeline.CostTracker, input_rate: 0.1, output_rate: 0.2}],
               %{}
             )

    assert primary.kind == :result
    assert injected.kind == :cost_update
    assert %Control.CostUpdate{cost_usd: 0.8} = injected.payload
    assert ctx.cost.cost_usd == 0.8
  end

  test "policy guard blocks disallowed tool and returns typed error" do
    tool_event =
      %Event{
        id: Event.generate_id(),
        kind: :tool_use,
        run_id: "run-pipeline-guard",
        session_id: "session-pipeline-guard",
        provider: :claude,
        payload: %Message.ToolUse{tool_name: "bash", tool_id: "tool-1", input: %{}},
        timestamp: DateTime.utc_now()
      }

    assert {:error, error, _ctx} =
             Pipeline.run(
               tool_event,
               [{ASM.Pipeline.PolicyGuard, disallow_tools: ["bash"]}],
               %{}
             )

    assert error.kind == :guardrail_blocked
    assert error.domain == :guardrail
  end
end
