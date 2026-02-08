defmodule AgentSessionManager.Core.TranscriptBuilderTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.InMemorySessionStore
  alias AgentSessionManager.Core.{Transcript, TranscriptBuilder}
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.Test.Fixtures

  describe "from_events/2" do
    test "builds ordered transcript messages and normalizes tool call ids" do
      now = DateTime.utc_now()

      events = [
        build_event(
          id: "evt-4",
          session_id: "ses-transcript",
          sequence_number: 4,
          timestamp: DateTime.add(now, 4, :second),
          type: :tool_call_completed,
          data: %{call_id: "call-1", tool_name: "search", output: %{"result" => "ok"}}
        ),
        build_event(
          id: "evt-2",
          session_id: "ses-transcript",
          sequence_number: 2,
          timestamp: DateTime.add(now, 2, :second),
          type: :tool_call_started,
          data: %{tool_use_id: "toolu-1", tool_name: "search", input: %{"q" => "elixir"}}
        ),
        build_event(
          id: "evt-1",
          session_id: "ses-transcript",
          sequence_number: 1,
          timestamp: DateTime.add(now, 1, :second),
          type: :message_sent,
          data: %{content: "find me something"}
        ),
        build_event(
          id: "evt-3",
          session_id: "ses-transcript",
          sequence_number: 3,
          timestamp: DateTime.add(now, 3, :second),
          type: :message_received,
          data: %{content: "working on it", role: "assistant"}
        )
      ]

      assert {:ok, %Transcript{} = transcript} =
               TranscriptBuilder.from_events(events, session_id: "ses-transcript")

      assert transcript.session_id == "ses-transcript"
      assert transcript.last_sequence == 4
      assert length(transcript.messages) == 4

      [user_msg, tool_start_msg, assistant_msg, tool_msg] = transcript.messages

      assert user_msg.role == :user
      assert user_msg.content == "find me something"

      assert tool_start_msg.role == :assistant
      assert tool_start_msg.tool_call_id == "toolu-1"
      assert tool_start_msg.tool_name == "search"
      assert tool_start_msg.tool_input == %{"q" => "elixir"}

      assert assistant_msg.role == :assistant
      assert assistant_msg.content == "working on it"

      assert tool_msg.role == :tool
      assert tool_msg.tool_call_id == "call-1"
      assert tool_msg.tool_output == %{"result" => "ok"}
    end

    test "uses timestamp then deterministic tie-breakers for legacy events without sequence" do
      now = DateTime.utc_now()

      events = [
        build_event(
          id: "evt-c",
          session_id: "ses-legacy",
          sequence_number: nil,
          timestamp: DateTime.add(now, 1, :second),
          type: :message_received,
          data: %{content: "later"}
        ),
        build_event(
          id: "evt-b",
          session_id: "ses-legacy",
          sequence_number: nil,
          timestamp: now,
          type: :message_received,
          data: %{content: "second"}
        ),
        build_event(
          id: "evt-seq",
          session_id: "ses-legacy",
          sequence_number: 1,
          timestamp: DateTime.add(now, 10, :second),
          type: :message_received,
          data: %{content: "sequenced first"}
        ),
        build_event(
          id: "evt-a",
          session_id: "ses-legacy",
          sequence_number: nil,
          timestamp: now,
          type: :message_received,
          data: %{content: "first"}
        )
      ]

      assert {:ok, %Transcript{} = transcript} =
               TranscriptBuilder.from_events(events, session_id: "ses-legacy")

      assert Enum.map(transcript.messages, & &1.content) == [
               "sequenced first",
               "first",
               "second",
               "later"
             ]
    end

    test "collapses streamed assistant chunks into a single assistant message when final arrives" do
      events = [
        build_event(
          id: "evt-1",
          session_id: "ses-stream",
          sequence_number: 1,
          type: :message_streamed,
          data: %{delta: "Hello"}
        ),
        build_event(
          id: "evt-2",
          session_id: "ses-stream",
          sequence_number: 2,
          type: :message_streamed,
          data: %{content: " world"}
        ),
        build_event(
          id: "evt-3",
          session_id: "ses-stream",
          sequence_number: 3,
          type: :message_received,
          data: %{content: "Hello world", role: "assistant"}
        )
      ]

      assert {:ok, %Transcript{} = transcript} =
               TranscriptBuilder.from_events(events, session_id: "ses-stream")

      assert length(transcript.messages) == 1
      message = hd(transcript.messages)
      assert message.role == :assistant
      assert message.content == "Hello world"
      assert message.tool_call_id == nil
    end
  end

  describe "from_store/3 and update_from_store/3" do
    test "builds and incrementally updates transcript from persisted store events" do
      {:ok, store} = InMemorySessionStore.start_link([])
      cleanup_on_exit(fn -> safe_stop(store) end)

      session_id = "ses-store-transcript"

      {:ok, _} =
        SessionStore.append_event_with_sequence(
          store,
          build_event(
            id: "evt-1",
            session_id: session_id,
            type: :message_sent,
            data: %{content: "hello"}
          )
        )

      {:ok, _} =
        SessionStore.append_event_with_sequence(
          store,
          build_event(
            id: "evt-2",
            session_id: session_id,
            type: :message_received,
            data: %{content: "hi there"}
          )
        )

      assert {:ok, %Transcript{} = transcript} =
               TranscriptBuilder.from_store(store, session_id, limit: 2)

      assert transcript.last_sequence == 2
      assert length(transcript.messages) == 2

      {:ok, _} =
        SessionStore.append_event_with_sequence(
          store,
          build_event(
            id: "evt-3",
            session_id: session_id,
            type: :message_received,
            data: %{content: "follow-up"}
          )
        )

      assert {:ok, %Transcript{} = updated} =
               TranscriptBuilder.update_from_store(store, transcript, limit: 1)

      assert updated.last_sequence == 3
      assert length(updated.messages) == 3
      assert List.last(updated.messages).content == "follow-up"
    end
  end

  defp build_event(opts) do
    Fixtures.build_event(opts)
  end
end
