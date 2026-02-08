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
end
