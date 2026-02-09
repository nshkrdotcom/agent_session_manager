defmodule AgentSessionManager.Policy.StackMergeTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Policy.Policy

  describe "stack_merge/1" do
    test "returns default policy for empty list" do
      result = Policy.stack_merge([])
      assert result.name == "default"
    end

    test "returns the single policy unchanged for single-element list" do
      {:ok, policy} = Policy.new(name: "only")
      assert Policy.stack_merge([policy]) == policy
    end

    test "merges names with separator" do
      {:ok, org} = Policy.new(name: "org")
      {:ok, team} = Policy.new(name: "team")

      result = Policy.stack_merge([org, team])
      assert result.name == "org + team"
    end

    test "later limits override earlier limits of the same type" do
      {:ok, org} = Policy.new(name: "org", limits: [{:max_total_tokens, 100_000}])
      {:ok, team} = Policy.new(name: "team", limits: [{:max_total_tokens, 50_000}])

      result = Policy.stack_merge([org, team])
      assert {:max_total_tokens, 50_000} in result.limits
    end

    test "preserves unique limits from both sides" do
      {:ok, org} = Policy.new(name: "org", limits: [{:max_total_tokens, 100_000}])
      {:ok, team} = Policy.new(name: "team", limits: [{:max_tool_calls, 10}])

      result = Policy.stack_merge([org, team])
      assert {:max_total_tokens, 100_000} in result.limits
      assert {:max_tool_calls, 10} in result.limits
    end

    test "concatenates tool rules from all policies" do
      {:ok, org} = Policy.new(name: "org", tool_rules: [{:deny, ["bash"]}])
      {:ok, team} = Policy.new(name: "team", tool_rules: [{:allow, ["search", "read"]}])

      result = Policy.stack_merge([org, team])
      assert length(result.tool_rules) == 2
      assert {:deny, ["bash"]} in result.tool_rules

      assert Enum.any?(result.tool_rules, fn
               {:allow, tools} -> Enum.sort(tools) == ["read", "search"]
               _ -> false
             end)
    end

    test "strictest on_violation wins (cancel > warn)" do
      {:ok, org} = Policy.new(name: "org", on_violation: :warn)
      {:ok, team} = Policy.new(name: "team", on_violation: :cancel)

      result = Policy.stack_merge([org, team])
      assert result.on_violation == :cancel
    end

    test "cancel is sticky regardless of position" do
      {:ok, first} = Policy.new(name: "first", on_violation: :cancel)
      {:ok, second} = Policy.new(name: "second", on_violation: :warn)

      result = Policy.stack_merge([first, second])
      assert result.on_violation == :cancel
    end

    test "deep-merges metadata from all policies" do
      {:ok, org} = Policy.new(name: "org", metadata: %{org_id: "org-1"})
      {:ok, team} = Policy.new(name: "team", metadata: %{team_id: "team-1"})

      result = Policy.stack_merge([org, team])
      assert result.metadata.org_id == "org-1"
      assert result.metadata.team_id == "team-1"
    end

    test "supports three-level merge (org + team + user)" do
      {:ok, org} =
        Policy.new(
          name: "org",
          limits: [{:max_total_tokens, 100_000}],
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :cancel
        )

      {:ok, team} =
        Policy.new(
          name: "team",
          limits: [{:max_tool_calls, 20}]
        )

      {:ok, user} =
        Policy.new(
          name: "user",
          limits: [{:max_duration_ms, 60_000}],
          on_violation: :warn
        )

      result = Policy.stack_merge([org, team, user])
      assert result.name == "org + team + user"
      assert {:max_total_tokens, 100_000} in result.limits
      assert {:max_tool_calls, 20} in result.limits
      assert {:max_duration_ms, 60_000} in result.limits
      assert {:deny, ["bash"]} in result.tool_rules
      # Cancel wins (strictest)
      assert result.on_violation == :cancel
    end
  end
end
