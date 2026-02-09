defmodule AgentSessionManager.Policy.PreflightTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Policy.{Policy, Preflight}

  describe "check/1" do
    test "returns :ok for a valid policy" do
      {:ok, policy} =
        Policy.new(
          name: "valid",
          limits: [{:max_total_tokens, 10_000}],
          tool_rules: [{:deny, ["bash"]}]
        )

      assert :ok = Preflight.check(policy)
    end

    test "rejects policy with empty allow list" do
      {:ok, policy} = Policy.new(name: "empty-allow", tool_rules: [{:allow, []}])

      assert {:error, %Error{code: :policy_violation}} = Preflight.check(policy)
    end

    test "rejects policy with zero max_total_tokens" do
      {:ok, policy} = Policy.new(name: "zero-tokens", limits: [{:max_total_tokens, 0}])

      assert {:error, %Error{code: :policy_violation}} = Preflight.check(policy)
    end

    test "rejects policy with zero max_tool_calls" do
      {:ok, policy} = Policy.new(name: "zero-tools", limits: [{:max_tool_calls, 0}])

      assert {:error, %Error{code: :policy_violation}} = Preflight.check(policy)
    end

    test "rejects policy with contradictory tool rules" do
      {:ok, policy} =
        Policy.new(
          name: "contradiction",
          tool_rules: [{:allow, ["bash", "read"]}, {:deny, ["bash"]}]
        )

      assert {:error, %Error{code: :policy_violation} = error} = Preflight.check(policy)
      assert error.details.check == :contradictory_rules
      assert "bash" in error.details.tools
    end

    test "passes policy with non-zero limits" do
      {:ok, policy} =
        Policy.new(
          name: "valid",
          limits: [{:max_total_tokens, 100}, {:max_tool_calls, 5}]
        )

      assert :ok = Preflight.check(policy)
    end

    test "returns :ok for nil policy input" do
      assert :ok = Preflight.check(nil)
    end
  end
end
