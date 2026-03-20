defmodule ASM.EventTest do
  use ASM.TestCase

  alias ASM.{Content, Control, Event, Message}
  alias CliSubprocessCore.Event, as: CoreEvent
  alias CliSubprocessCore.Payload

  test "generate_id/0 returns 26-char crockford base32 id" do
    id = Event.generate_id()

    assert String.length(id) == 26
    assert id =~ ~r/^[0-9A-HJKMNP-TV-Z]{26}$/
  end

  test "generate_id_at/1 returns different ids for same timestamp" do
    timestamp = 1_700_000_000_000
    id1 = Event.generate_id_at(timestamp)
    id2 = Event.generate_id_at(timestamp)

    assert id1 != id2
  end

  test "generate_id_at/1 validates input" do
    assert_raise ArgumentError, fn -> Event.generate_id_at(-1) end
    assert_raise ArgumentError, fn -> Event.generate_id_at("bad") end
  end

  test "wrap_core/2 preserves run scope around normalized core events" do
    core_event =
      CoreEvent.new(:assistant_delta,
        provider: :claude,
        payload: Payload.AssistantDelta.new(content: "hello")
      )

    event =
      Event.wrap_core(%{run_id: "run-1", session_id: "session-1", provider: :claude}, core_event)

    assert event.run_id == "run-1"
    assert event.session_id == "session-1"
    assert event.kind == :assistant_delta
    assert event.payload == core_event.payload
    assert event.core_event == core_event
  end

  test "legacy_payload/1 projects core payloads into ASM message/control structs" do
    assistant_message =
      Event.new(
        :assistant_message,
        Payload.AssistantMessage.new(
          content: [%{"type" => "text", "text" => "done"}],
          model: "claude-3-7"
        ),
        run_id: "run-1",
        session_id: "session-1"
      )

    approval =
      Event.new(
        :approval_requested,
        Payload.ApprovalRequested.new(
          approval_id: "approval-1",
          subject: "bash",
          details: %{"tool_input" => %{"cmd" => "ls"}}
        ),
        run_id: "run-1",
        session_id: "session-1"
      )

    result =
      Event.new(
        :result,
        Payload.Result.new(
          status: :completed,
          stop_reason: :end_turn,
          output: %{usage: %{input_tokens: 2, output_tokens: 3}}
        ),
        run_id: "run-1",
        session_id: "session-1"
      )

    assert %Message.Assistant{content: [%Content.Text{text: "done"}], model: "claude-3-7"} =
             Event.legacy_payload(assistant_message)

    assert %Control.ApprovalRequest{approval_id: "approval-1", tool_name: "bash"} =
             Event.legacy_payload(approval)

    assert %Message.Result{stop_reason: :end_turn, usage: %{input_tokens: 2, output_tokens: 3}} =
             Event.legacy_payload(result)
  end
end
