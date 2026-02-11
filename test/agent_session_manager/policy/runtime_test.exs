defmodule AgentSessionManager.Policy.RuntimeTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Policy.{Policy, Runtime}

  describe "observe_event/2" do
    test "requests cancel exactly once for cancel-mode violations" do
      {:ok, policy} =
        Policy.new(
          name: "tool-guard",
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :cancel
        )

      {:ok, runtime} =
        Runtime.start_link(policy: policy, provider: "codex", run_id: "run-policy-1")

      cleanup_on_exit(fn -> safe_stop(runtime) end)

      event = %{type: :tool_call_started, data: %{tool_name: "bash"}}

      assert {:ok, first_decision} = Runtime.observe_event(runtime, event)
      assert first_decision.cancel? == true
      assert length(first_decision.violations) == 1

      assert {:ok, second_decision} = Runtime.observe_event(runtime, event)
      assert second_decision.cancel? == false
      assert length(second_decision.violations) == 1
    end

    test "tracks warn-mode violations without cancellation" do
      {:ok, policy} =
        Policy.new(
          name: "warn-only",
          limits: [{:max_total_tokens, 10}],
          on_violation: :warn
        )

      {:ok, runtime} =
        Runtime.start_link(policy: policy, provider: "codex", run_id: "run-policy-2")

      cleanup_on_exit(fn -> safe_stop(runtime) end)

      usage_event = %{type: :token_usage_updated, data: %{input_tokens: 8, output_tokens: 8}}

      assert {:ok, decision} = Runtime.observe_event(runtime, usage_event)
      assert decision.cancel? == false
      assert length(decision.violations) == 1

      status = Runtime.status(runtime)
      assert status.cancel_requested? == false
      assert status.violated? == true
      assert length(status.violations) == 1
    end
  end

  describe "model-aware cost tracking" do
    @model_aware_rates %{
      "claude" => %{
        default: %{input: 0.000003, output: 0.000015},
        models: %{
          "claude-opus-4-6" => %{input: 0.000015, output: 0.000075}
        }
      }
    }

    test "captures model from run_started event and uses model-specific rates" do
      {:ok, policy} =
        Policy.new(
          name: "cost-model",
          limits: [{:max_cost_usd, 1.0}],
          on_violation: :cancel
        )

      {:ok, runtime} =
        Runtime.start_link(
          policy: policy,
          provider: "claude",
          run_id: "run-model-1",
          cost_rates: @model_aware_rates
        )

      cleanup_on_exit(fn -> safe_stop(runtime) end)

      {:ok, _} =
        Runtime.observe_event(runtime, %{
          type: :run_started,
          data: %{model: "claude-opus-4-6"}
        })

      {:ok, _} =
        Runtime.observe_event(runtime, %{
          type: :token_usage_updated,
          data: %{input_tokens: 1000, output_tokens: 500}
        })

      status = Runtime.status(runtime)
      expected_cost = 1000 * 0.000015 + 500 * 0.000075
      assert_in_delta status.usage.accumulated_cost_usd, expected_cost, 0.000001
    end

    test "falls back to provider default rates when model not captured" do
      {:ok, policy} =
        Policy.new(
          name: "cost-default",
          limits: [{:max_cost_usd, 1.0}],
          on_violation: :cancel
        )

      {:ok, runtime} =
        Runtime.start_link(
          policy: policy,
          provider: "claude",
          run_id: "run-model-2",
          cost_rates: @model_aware_rates
        )

      cleanup_on_exit(fn -> safe_stop(runtime) end)

      {:ok, _} =
        Runtime.observe_event(runtime, %{
          type: :token_usage_updated,
          data: %{input_tokens: 1000, output_tokens: 500}
        })

      status = Runtime.status(runtime)
      expected_cost = 1000 * 0.000003 + 500 * 0.000015
      assert_in_delta status.usage.accumulated_cost_usd, expected_cost, 0.000001
    end

    test "legacy flat rates still work (backward compatibility)" do
      legacy_rates = %{"claude" => %{input: 0.000003, output: 0.000015}}

      {:ok, policy} =
        Policy.new(
          name: "cost-legacy",
          limits: [{:max_cost_usd, 1.0}],
          on_violation: :cancel
        )

      {:ok, runtime} =
        Runtime.start_link(
          policy: policy,
          provider: "claude",
          run_id: "run-legacy",
          cost_rates: legacy_rates
        )

      cleanup_on_exit(fn -> safe_stop(runtime) end)

      {:ok, _} =
        Runtime.observe_event(runtime, %{
          type: :token_usage_updated,
          data: %{input_tokens: 1000, output_tokens: 500}
        })

      status = Runtime.status(runtime)
      expected_cost = 1000 * 0.000003 + 500 * 0.000015
      assert_in_delta status.usage.accumulated_cost_usd, expected_cost, 0.000001
    end
  end
end
