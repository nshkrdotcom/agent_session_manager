defmodule ASM.Pipeline.CostTrackerTest do
  use ASM.TestCase

  alias ASM.Event
  alias ASM.Pipeline.CostTracker
  alias CliSubprocessCore.Payload

  test "ignores delta-only result usage for aggregate totals" do
    event =
      Event.new(
        :result,
        Payload.Result.new(
          status: :completed,
          stop_reason: :end_turn,
          output: %{
            usage: %{input_tokens: 2, output_tokens: 3, usage_scope: "delta"}
          }
        ),
        run_id: "run-cost-delta",
        session_id: "session-cost-delta",
        provider: :codex,
        metadata: %{usage_scope: "delta"}
      )

    assert {:ok, ^event, [], %{cost: %{input_tokens: 5, output_tokens: 8, cost_usd: 1.3}}} =
             CostTracker.call(event, %{cost: %{input_tokens: 5, output_tokens: 8, cost_usd: 1.3}},
               input_rate: 0.1,
               output_rate: 0.2
             )
  end

  test "accounts absolute result usage as the completed run total" do
    event =
      Event.new(
        :result,
        Payload.Result.new(
          status: :completed,
          stop_reason: :end_turn,
          output: %{usage: %{input_tokens: 2, output_tokens: 3}}
        ),
        run_id: "run-cost-absolute",
        session_id: "session-cost-absolute",
        provider: :codex,
        metadata: %{usage_scope: "absolute"}
      )

    assert {:ok, ^event, [cost_event], %{cost: totals}} =
             CostTracker.call(event, %{cost: %{input_tokens: 5, output_tokens: 8, cost_usd: 1.3}},
               input_rate: 0.1,
               output_rate: 0.2
             )

    assert totals == %{input_tokens: 7, output_tokens: 11, cost_usd: 2.1}
    assert cost_event.kind == :cost_update
    assert cost_event.payload.input_tokens == 2
    assert cost_event.payload.output_tokens == 3
  end
end
