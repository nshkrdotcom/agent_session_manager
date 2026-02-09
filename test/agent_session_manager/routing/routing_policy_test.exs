defmodule AgentSessionManager.Routing.RoutingPolicyTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Routing.RoutingPolicy

  describe "order_candidates/2 with :prefer strategy" do
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

    test "defaults to :prefer strategy" do
      policy = RoutingPolicy.new(prefer: ["amp"])
      assert policy.strategy == :prefer
    end
  end

  describe "order_candidates/3 with :weighted strategy" do
    test "orders candidates by weight descending" do
      policy =
        RoutingPolicy.new(
          strategy: :weighted,
          weights: %{"amp" => 10, "codex" => 5, "claude" => 1}
        )

      candidates = [%{id: "claude"}, %{id: "codex"}, %{id: "amp"}]

      ordered = RoutingPolicy.order_candidates(policy, candidates)
      assert Enum.map(ordered, & &1.id) == ["amp", "codex", "claude"]
    end

    test "applies health penalty to reduce effective score" do
      policy =
        RoutingPolicy.new(
          strategy: :weighted,
          weights: %{"amp" => 10, "codex" => 5, "claude" => 1}
        )

      health = %{
        "amp" => %{failure_count: 20, last_failure_at: nil}
      }

      candidates = [%{id: "claude"}, %{id: "codex"}, %{id: "amp"}]

      ordered = RoutingPolicy.order_candidates(policy, candidates, health: health)
      # amp: 10 - 20*0.5 = 0, codex: 5, claude: 1
      assert Enum.map(ordered, & &1.id) == ["codex", "claude", "amp"]
    end

    test "breaks ties using prefer order" do
      policy =
        RoutingPolicy.new(
          strategy: :weighted,
          weights: %{"amp" => 5, "codex" => 5},
          prefer: ["codex", "amp"]
        )

      candidates = [%{id: "amp"}, %{id: "codex"}]

      ordered = RoutingPolicy.order_candidates(policy, candidates)
      assert Enum.map(ordered, & &1.id) == ["codex", "amp"]
    end

    test "applies exclude filter before scoring" do
      policy =
        RoutingPolicy.new(
          strategy: :weighted,
          weights: %{"amp" => 10, "codex" => 5, "claude" => 1},
          exclude: ["amp"]
        )

      candidates = [%{id: "claude"}, %{id: "codex"}, %{id: "amp"}]

      ordered = RoutingPolicy.order_candidates(policy, candidates)
      assert Enum.map(ordered, & &1.id) == ["codex", "claude"]
    end

    test "assigns default weight of 1.0 to unlisted adapters" do
      policy =
        RoutingPolicy.new(
          strategy: :weighted,
          weights: %{"amp" => 0.5}
        )

      candidates = [%{id: "amp"}, %{id: "codex"}]

      ordered = RoutingPolicy.order_candidates(policy, candidates)
      # codex: 1.0 (default), amp: 0.5
      assert Enum.map(ordered, & &1.id) == ["codex", "amp"]
    end
  end

  describe "score/3" do
    test "returns base weight minus health penalty" do
      policy = RoutingPolicy.new(strategy: :weighted, weights: %{"amp" => 10})
      health = %{"amp" => %{failure_count: 4}}

      # 10 - 4*0.5 = 8.0
      assert RoutingPolicy.score(policy, "amp", health) == 8.0
    end

    test "returns default weight when adapter not in weights" do
      policy = RoutingPolicy.new(strategy: :weighted, weights: %{})
      assert RoutingPolicy.score(policy, "codex", %{}) == 1.0
    end

    test "returns negative score for heavily penalized adapters" do
      policy = RoutingPolicy.new(strategy: :weighted, weights: %{"amp" => 1})
      health = %{"amp" => %{failure_count: 10}}
      assert RoutingPolicy.score(policy, "amp", health) == -4.0
    end
  end

  describe "strategy field" do
    test "can be set to :weighted" do
      policy = RoutingPolicy.new(strategy: :weighted)
      assert policy.strategy == :weighted
    end

    test "defaults to :prefer for invalid values" do
      policy = RoutingPolicy.new(strategy: :invalid)
      assert policy.strategy == :prefer
    end

    test "is preserved through merge" do
      base = RoutingPolicy.new(strategy: :weighted)
      merged = RoutingPolicy.merge(base, %{max_attempts: 5})
      assert merged.strategy == :weighted
    end

    test "can be overridden in merge" do
      base = RoutingPolicy.new(strategy: :prefer)
      merged = RoutingPolicy.merge(base, %{strategy: :weighted})
      assert merged.strategy == :weighted
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
