defmodule AgentSessionManager.Policy.ApprovalPolicyTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Policy.Policy

  describe "on_violation: :request_approval" do
    test "Policy.new accepts :request_approval" do
      assert {:ok, %Policy{on_violation: :request_approval}} =
               Policy.new(name: "approval-test", on_violation: :request_approval)
    end

    test "Policy.new still accepts :cancel" do
      assert {:ok, %Policy{on_violation: :cancel}} =
               Policy.new(name: "cancel-test", on_violation: :cancel)
    end

    test "Policy.new still accepts :warn" do
      assert {:ok, %Policy{on_violation: :warn}} =
               Policy.new(name: "warn-test", on_violation: :warn)
    end

    test "Policy.new still rejects invalid values" do
      assert {:error, _} = Policy.new(name: "invalid", on_violation: :block)
      assert {:error, _} = Policy.new(name: "invalid", on_violation: :approve)
    end
  end

  describe "stack_merge strictness: cancel > request_approval > warn" do
    test "request_approval is stricter than warn" do
      {:ok, p1} = Policy.new(name: "p1", on_violation: :request_approval)
      {:ok, p2} = Policy.new(name: "p2", on_violation: :warn)

      merged = Policy.stack_merge([p1, p2])
      assert merged.on_violation == :request_approval
    end

    test "warn does not override request_approval" do
      {:ok, p1} = Policy.new(name: "p1", on_violation: :warn)
      {:ok, p2} = Policy.new(name: "p2", on_violation: :request_approval)

      merged = Policy.stack_merge([p1, p2])
      assert merged.on_violation == :request_approval
    end

    test "cancel is stricter than request_approval" do
      {:ok, p1} = Policy.new(name: "p1", on_violation: :request_approval)
      {:ok, p2} = Policy.new(name: "p2", on_violation: :cancel)

      merged = Policy.stack_merge([p1, p2])
      assert merged.on_violation == :cancel
    end

    test "request_approval does not override cancel" do
      {:ok, p1} = Policy.new(name: "p1", on_violation: :cancel)
      {:ok, p2} = Policy.new(name: "p2", on_violation: :request_approval)

      merged = Policy.stack_merge([p1, p2])
      assert merged.on_violation == :cancel
    end

    test "three-level merge with request_approval" do
      {:ok, org} = Policy.new(name: "org", on_violation: :warn)
      {:ok, team} = Policy.new(name: "team", on_violation: :request_approval)
      {:ok, user} = Policy.new(name: "user", on_violation: :warn)

      merged = Policy.stack_merge([org, team, user])
      assert merged.on_violation == :request_approval
    end
  end
end
