defmodule AgentSessionManager.Routing.RoutingPolicyTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Routing.RoutingPolicy

  describe "order_candidates/2" do
    test "applies exclusions first, then preference ordering" do
      policy = RoutingPolicy.new(prefer: ["amp", "codex"], exclude: ["claude"])

      candidates = [
        %{id: "codex"},
        %{id: "claude"},
        %{id: "amp"},
        %{id: "other"}
      ]

      ordered = RoutingPolicy.order_candidates(policy, candidates)

      assert Enum.map(ordered, & &1.id) == ["amp", "codex", "other"]
    end
  end

  describe "attempt_limit/2" do
    test "caps attempts by max_attempts and candidate count" do
      policy = RoutingPolicy.new(max_attempts: 2)

      assert RoutingPolicy.attempt_limit(policy, 5) == 2
      assert RoutingPolicy.attempt_limit(policy, 1) == 1
    end
  end

  describe "merge/2" do
    test "allows per-execution overrides" do
      base = RoutingPolicy.new(prefer: ["codex"], max_attempts: 1)

      merged =
        RoutingPolicy.merge(base, %{
          prefer: ["amp"],
          exclude: ["claude"],
          max_attempts: 3
        })

      assert merged.prefer == ["amp"]
      assert merged.exclude == ["claude"]
      assert merged.max_attempts == 3
    end
  end
end
