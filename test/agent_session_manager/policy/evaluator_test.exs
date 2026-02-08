defmodule AgentSessionManager.Policy.EvaluatorTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Policy.{Evaluator, Policy}

  describe "evaluate/4" do
    test "detects tool deny-rule violations" do
      {:ok, policy} =
        Policy.new(
          name: "deny-bash",
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :cancel
        )

      runtime_state = %{tool_calls: 0, total_tokens: 0, elapsed_ms: 0, accumulated_cost_usd: 0.0}

      event = %{type: :tool_call_started, data: %{tool_name: "bash"}}

      assert violations = Evaluator.evaluate(policy, runtime_state, event, provider: "codex")
      assert Enum.any?(violations, &(&1.kind == :tool_denied))
      assert Enum.any?(violations, &(&1.action == :cancel))
    end

    test "detects max_total_tokens violations from usage events" do
      {:ok, policy} =
        Policy.new(
          name: "token-budget",
          limits: [{:max_total_tokens, 100}],
          on_violation: :cancel
        )

      runtime_state = %{
        tool_calls: 0,
        total_tokens: 120,
        elapsed_ms: 0,
        accumulated_cost_usd: 0.0
      }

      event = %{type: :token_usage_updated, data: %{total_tokens: 120}}

      assert violations = Evaluator.evaluate(policy, runtime_state, event, provider: "codex")
      assert Enum.any?(violations, &(&1.kind == :budget_exceeded))
    end

    test "skips cost-limit violations when provider rates are unavailable" do
      {:ok, policy} =
        Policy.new(
          name: "cost-budget",
          limits: [{:max_cost_usd, 0.001}],
          on_violation: :warn
        )

      runtime_state = %{tool_calls: 0, total_tokens: 0, elapsed_ms: 0, accumulated_cost_usd: 0.01}

      event = %{type: :token_usage_updated, data: %{input_tokens: 1000, output_tokens: 500}}

      assert [] = Evaluator.evaluate(policy, runtime_state, event, provider: "unknown-provider")
    end
  end
end
