defmodule AgentSessionManager.Core.ApprovalEventsTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Event

  describe "approval event types" do
    test "tool_approval_requested is a valid event type" do
      assert Event.valid_type?(:tool_approval_requested)
    end

    test "tool_approval_granted is a valid event type" do
      assert Event.valid_type?(:tool_approval_granted)
    end

    test "tool_approval_denied is a valid event type" do
      assert Event.valid_type?(:tool_approval_denied)
    end

    test "approval_events/0 returns the approval event list" do
      events = Event.approval_events()
      assert :tool_approval_requested in events
      assert :tool_approval_granted in events
      assert :tool_approval_denied in events
      assert length(events) == 3
    end

    test "approval events are included in all_types/0" do
      all = Event.all_types()
      assert :tool_approval_requested in all
      assert :tool_approval_granted in all
      assert :tool_approval_denied in all
    end

    test "can create Event with approval type" do
      assert {:ok, event} =
               Event.new(%{
                 type: :tool_approval_requested,
                 session_id: "ses-test",
                 run_id: "run-test",
                 data: %{
                   tool_name: "bash",
                   tool_call_id: "toolu_123",
                   tool_input: %{command: "rm -rf /tmp"},
                   policy_name: "production-safety",
                   violation_kind: :tool_denied
                 }
               })

      assert event.type == :tool_approval_requested
      assert event.data.tool_name == "bash"
    end

    test "can create Event with tool_approval_granted type" do
      assert {:ok, event} =
               Event.new(%{
                 type: :tool_approval_granted,
                 session_id: "ses-test",
                 data: %{
                   tool_name: "bash",
                   tool_call_id: "toolu_123",
                   approved_by: "admin@example.com"
                 }
               })

      assert event.type == :tool_approval_granted
    end

    test "can create Event with tool_approval_denied type" do
      assert {:ok, event} =
               Event.new(%{
                 type: :tool_approval_denied,
                 session_id: "ses-test",
                 data: %{
                   tool_name: "bash",
                   denial_reason: "Too dangerous"
                 }
               })

      assert event.type == :tool_approval_denied
    end
  end
end
