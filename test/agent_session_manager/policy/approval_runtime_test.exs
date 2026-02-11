defmodule AgentSessionManager.Policy.ApprovalRuntimeTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Policy.{Policy, Runtime}

  describe "observe_event/2 with request_approval mode" do
    test "returns request_approval?: true on first violation" do
      {:ok, policy} =
        Policy.new(
          name: "approval-guard",
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :request_approval
        )

      {:ok, runtime} =
        Runtime.start_link(policy: policy, provider: "test", run_id: "run-approval-1")

      cleanup_on_exit(fn -> safe_stop(runtime) end)

      event = %{type: :tool_call_started, data: %{tool_name: "bash"}}

      assert {:ok, decision} = Runtime.observe_event(runtime, event)
      assert decision.request_approval? == true
      assert decision.cancel? == false
      assert length(decision.violations) == 1
    end

    test "returns request_approval?: false on subsequent violations (fires once)" do
      {:ok, policy} =
        Policy.new(
          name: "approval-guard",
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :request_approval
        )

      {:ok, runtime} =
        Runtime.start_link(policy: policy, provider: "test", run_id: "run-approval-2")

      cleanup_on_exit(fn -> safe_stop(runtime) end)

      event = %{type: :tool_call_started, data: %{tool_name: "bash"}}

      {:ok, first} = Runtime.observe_event(runtime, event)
      assert first.request_approval? == true

      {:ok, second} = Runtime.observe_event(runtime, event)
      assert second.request_approval? == false
      assert length(second.violations) == 1
    end

    test "cancel mode does not set request_approval?" do
      {:ok, policy} =
        Policy.new(
          name: "cancel-guard",
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :cancel
        )

      {:ok, runtime} =
        Runtime.start_link(policy: policy, provider: "test", run_id: "run-cancel-3")

      cleanup_on_exit(fn -> safe_stop(runtime) end)

      event = %{type: :tool_call_started, data: %{tool_name: "bash"}}

      {:ok, decision} = Runtime.observe_event(runtime, event)
      assert decision.cancel? == true
      assert decision.request_approval? == false
    end

    test "warn mode does not set request_approval?" do
      {:ok, policy} =
        Policy.new(
          name: "warn-guard",
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :warn
        )

      {:ok, runtime} =
        Runtime.start_link(policy: policy, provider: "test", run_id: "run-warn-4")

      cleanup_on_exit(fn -> safe_stop(runtime) end)

      event = %{type: :tool_call_started, data: %{tool_name: "bash"}}

      {:ok, decision} = Runtime.observe_event(runtime, event)
      assert decision.cancel? == false
      assert decision.request_approval? == false
    end

    test "non-violating events return request_approval?: false" do
      {:ok, policy} =
        Policy.new(
          name: "approval-guard",
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :request_approval
        )

      {:ok, runtime} =
        Runtime.start_link(policy: policy, provider: "test", run_id: "run-approval-5")

      cleanup_on_exit(fn -> safe_stop(runtime) end)

      event = %{type: :tool_call_started, data: %{tool_name: "search"}}

      {:ok, decision} = Runtime.observe_event(runtime, event)
      assert decision.request_approval? == false
      assert decision.violations == []
    end

    test "status reflects approval_requested state" do
      {:ok, policy} =
        Policy.new(
          name: "approval-guard",
          tool_rules: [{:deny, ["bash"]}],
          on_violation: :request_approval
        )

      {:ok, runtime} =
        Runtime.start_link(policy: policy, provider: "test", run_id: "run-approval-6")

      cleanup_on_exit(fn -> safe_stop(runtime) end)

      event = %{type: :tool_call_started, data: %{tool_name: "bash"}}
      {:ok, _} = Runtime.observe_event(runtime, event)

      status = Runtime.status(runtime)
      assert status.violated? == true
      assert status.action == :request_approval
      assert status.approval_requested? == true
    end
  end
end
