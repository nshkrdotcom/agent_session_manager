defmodule ASM.Extensions.Policy.ContractTest do
  use ASM.TestCase

  alias ASM.{Event, Message}
  alias ASM.Extensions.Policy
  alias ASM.Extensions.Policy.Violation

  test "new/1 validates policy definition contract" do
    assert {:ok, policy} =
             Policy.new(
               disallow_tools: ["bash", :mcp],
               max_output_tokens: 20,
               on_tool_violation: :request_approval,
               on_budget_violation: :warn
             )

    assert MapSet.new(["bash", "mcp"]) == policy.disallow_tools
    assert policy.max_output_tokens == 20
    assert policy.on_tool_violation == :request_approval
    assert policy.on_budget_violation == :warn

    assert {:error, error} = Policy.new(on_tool_violation: :invalid_action)
    assert error.kind == :config_invalid
    assert error.domain == :config
  end

  test "evaluate/3 returns a violation for denied tools" do
    policy = Policy.new!(disallow_tools: ["bash"], on_tool_violation: :cancel)
    event = tool_event("bash")

    assert {:violation, %Violation{} = violation, ctx} = Policy.evaluate(policy, event, %{})

    assert violation.rule == :tool_disallowed
    assert violation.action == :cancel
    assert violation.direction == :input
    assert violation.metadata.tool_name == "bash"
    assert ctx == %{}
  end

  test "evaluate/3 enforces cumulative output token budget" do
    policy = Policy.new!(max_output_tokens: 5, on_budget_violation: :warn)

    assert {:ok, ctx} = Policy.evaluate(policy, result_event(3), %{})
    assert get_in(ctx, [:policy, :output_tokens]) == 3

    assert {:violation, %Violation{} = violation, next_ctx} =
             Policy.evaluate(policy, result_event(4), ctx)

    assert violation.rule == :output_budget_exceeded
    assert violation.action == :warn
    assert violation.direction == :output
    assert violation.metadata.max_output_tokens == 5
    assert violation.metadata.total_output_tokens == 7
    assert get_in(next_ctx, [:policy, :output_tokens]) == 7
  end

  defp tool_event(tool_name) do
    %Event{
      id: Event.generate_id(),
      kind: :tool_use,
      run_id: "run-ext-policy-contract",
      session_id: "session-ext-policy-contract",
      provider: :claude,
      payload: %Message.ToolUse{tool_name: tool_name, tool_id: "tool-ext-policy-1", input: %{}},
      timestamp: DateTime.utc_now()
    }
  end

  defp result_event(output_tokens) do
    %Event{
      id: Event.generate_id(),
      kind: :result,
      run_id: "run-ext-policy-contract",
      session_id: "session-ext-policy-contract",
      provider: :claude,
      payload: %Message.Result{stop_reason: :end_turn, usage: %{output_tokens: output_tokens}},
      timestamp: DateTime.utc_now()
    }
  end
end
