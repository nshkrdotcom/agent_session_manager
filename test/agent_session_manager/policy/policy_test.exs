defmodule AgentSessionManager.Policy.PolicyTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Policy.Policy

  describe "new/1" do
    test "builds a valid policy struct" do
      assert {:ok, policy} =
               Policy.new(
                 name: "production",
                 limits: [{:max_total_tokens, 2_000}, {:max_tool_calls, 4}],
                 tool_rules: [{:deny, ["bash"]}],
                 on_violation: :cancel,
                 metadata: %{env: "prod"}
               )

      assert policy.name == "production"
      assert policy.on_violation == :cancel
      assert {:max_total_tokens, 2_000} in policy.limits
      assert {:deny, ["bash"]} in policy.tool_rules
      assert policy.metadata.env == "prod"
    end

    test "rejects invalid violation actions" do
      assert {:error, %Error{code: :validation_error}} =
               Policy.new(name: "invalid", on_violation: :block)
    end
  end

  describe "merge/2" do
    test "overrides selected fields while preserving others" do
      {:ok, base_policy} =
        Policy.new(
          name: "base",
          limits: [{:max_total_tokens, 500}],
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :warn,
          metadata: %{source: :base}
        )

      merged =
        Policy.merge(base_policy, %{
          limits: [{:max_total_tokens, 100}],
          on_violation: :cancel
        })

      assert merged.name == "base"
      assert merged.limits == [{:max_total_tokens, 100}]
      assert merged.tool_rules == [{:deny, ["bash"]}]
      assert merged.on_violation == :cancel
      assert merged.metadata.source == :base
    end
  end
end
