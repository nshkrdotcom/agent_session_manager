defmodule AgentSessionManager.Core.EventNormalizerTest do
  @moduledoc """
  Tests for event normalization pipeline and ordering guarantees.

  Following TDD: these tests specify the behavior of the EventNormalizer
  before implementation.
  """
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Core.EventNormalizer
  alias AgentSessionManager.Core.NormalizedEvent

  describe "EventNormalizer.normalize/2 - basic normalization" do
    test "normalizes a raw event map into NormalizedEvent" do
      raw_event = %{
        "type" => "message_received",
        "content" => "Hello, world!",
        "role" => "assistant"
      }

      context = %{
        session_id: "ses_123",
        run_id: "run_456",
        provider: :generic
      }

      assert {:ok, normalized} = EventNormalizer.normalize(raw_event, context)

      assert %NormalizedEvent{} = normalized
      assert normalized.session_id == "ses_123"
      assert normalized.run_id == "run_456"
      assert normalized.provider == :generic
    end

    test "preserves raw data in event data field" do
      raw_event = %{
        "type" => "message_received",
        "content" => "Test content",
        "metadata" => %{"key" => "value"}
      }

      context = %{session_id: "ses_123", run_id: "run_456", provider: :generic}

      {:ok, normalized} = EventNormalizer.normalize(raw_event, context)

      assert normalized.data[:content] == "Test content"
      assert normalized.data[:raw] == raw_event
    end

    test "requires session_id in context" do
      raw_event = %{"type" => "message_received"}
      context = %{run_id: "run_456"}

      assert {:error, %Error{code: :validation_error}} =
               EventNormalizer.normalize(raw_event, context)
    end

    test "requires run_id in context" do
      raw_event = %{"type" => "message_received"}
      context = %{session_id: "ses_123"}

      assert {:error, %Error{code: :validation_error}} =
               EventNormalizer.normalize(raw_event, context)
    end
  end

  describe "EventNormalizer.normalize_batch/2 - batch normalization" do
    test "normalizes a list of raw events" do
      raw_events = [
        %{"type" => "message_received", "content" => "First"},
        %{"type" => "message_received", "content" => "Second"},
        %{"type" => "message_received", "content" => "Third"}
      ]

      context = %{session_id: "ses_123", run_id: "run_456", provider: :generic}

      assert {:ok, normalized_list} = EventNormalizer.normalize_batch(raw_events, context)

      assert length(normalized_list) == 3
      assert Enum.all?(normalized_list, &match?(%NormalizedEvent{}, &1))
    end

    test "assigns sequential sequence numbers" do
      raw_events = [
        %{"type" => "message_received", "content" => "First"},
        %{"type" => "message_received", "content" => "Second"},
        %{"type" => "message_received", "content" => "Third"}
      ]

      context = %{session_id: "ses_123", run_id: "run_456", provider: :generic}

      {:ok, normalized_list} = EventNormalizer.normalize_batch(raw_events, context)

      sequence_numbers = Enum.map(normalized_list, & &1.sequence_number)
      assert sequence_numbers == [0, 1, 2]
    end

    test "assigns sequence numbers starting from given offset" do
      raw_events = [
        %{"type" => "message_received", "content" => "First"},
        %{"type" => "message_received", "content" => "Second"}
      ]

      context = %{
        session_id: "ses_123",
        run_id: "run_456",
        provider: :generic,
        sequence_offset: 10
      }

      {:ok, normalized_list} = EventNormalizer.normalize_batch(raw_events, context)

      sequence_numbers = Enum.map(normalized_list, & &1.sequence_number)
      assert sequence_numbers == [10, 11]
    end

    test "handles events with missing type by converting to error_occurred" do
      # Events without a type are converted to error_occurred, not rejected
      # This allows the pipeline to continue processing without losing events
      raw_events = [
        %{"type" => "message_received", "content" => "Valid"},
        # No type - will become error_occurred
        %{},
        %{"type" => "message_received", "content" => "Also valid"}
      ]

      context = %{session_id: "ses_123", run_id: "run_456", provider: :generic}

      # All events should succeed (unknown types become error_occurred)
      assert {:ok, normalized_list} = EventNormalizer.normalize_batch(raw_events, context)

      assert length(normalized_list) == 3
      # The middle event should be error_occurred
      types = Enum.map(normalized_list, & &1.type)
      assert types == [:message_received, :error_occurred, :message_received]
    end
  end

  describe "EventNormalizer - event type mapping" do
    test "maps canonical string event types" do
      context = %{session_id: "ses_123", run_id: "run_456", provider: :generic}

      {:ok, event} = EventNormalizer.normalize(%{"type" => "message_received"}, context)
      assert event.type == :message_received

      {:ok, event} =
        EventNormalizer.normalize(%{"type" => "message_streamed", "delta" => "text"}, context)

      assert event.type == :message_streamed
      {:ok, event} = EventNormalizer.normalize(%{"type" => "tool_call_started"}, context)
      assert event.type == :tool_call_started
      {:ok, event} = EventNormalizer.normalize(%{"type" => "run_started"}, context)
      assert event.type == :run_started
      {:ok, event} = EventNormalizer.normalize(%{"type" => "run_completed"}, context)
      assert event.type == :run_completed
    end

    test "handles unknown types gracefully with error event" do
      context = %{session_id: "ses_123", run_id: "run_456", provider: :generic}

      {:ok, event} = EventNormalizer.normalize(%{"type" => "unknown_xyz"}, context)

      # Unknown types become error_occurred with the raw type preserved
      assert event.type == :error_occurred
      assert event.data[:original_type] == "unknown_xyz"
    end
  end

  describe "resolve_type/1 for approval events" do
    test "resolves :tool_approval_requested atom" do
      assert EventNormalizer.resolve_type(:tool_approval_requested) == :tool_approval_requested
    end

    test "resolves :tool_approval_granted atom" do
      assert EventNormalizer.resolve_type(:tool_approval_granted) == :tool_approval_granted
    end

    test "resolves :tool_approval_denied atom" do
      assert EventNormalizer.resolve_type(:tool_approval_denied) == :tool_approval_denied
    end

    test "resolves \"tool_approval_requested\" string" do
      assert EventNormalizer.resolve_type("tool_approval_requested") == :tool_approval_requested
    end

    test "resolves \"tool_approval_granted\" string" do
      assert EventNormalizer.resolve_type("tool_approval_granted") == :tool_approval_granted
    end

    test "resolves \"tool_approval_denied\" string" do
      assert EventNormalizer.resolve_type("tool_approval_denied") == :tool_approval_denied
    end
  end

  describe "EventNormalizer - ordering guarantees" do
    test "timestamps are monotonically increasing for batch events" do
      raw_events = for i <- 1..10, do: %{"type" => "message_received", "index" => i}
      context = %{session_id: "ses_123", run_id: "run_456", provider: :generic}

      {:ok, normalized_list} = EventNormalizer.normalize_batch(raw_events, context)

      timestamps = Enum.map(normalized_list, & &1.timestamp)

      # Each timestamp should be >= previous
      timestamps
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [t1, t2] ->
        assert DateTime.compare(t2, t1) in [:gt, :eq],
               "Timestamps must be monotonically increasing"
      end)
    end

    test "sequence numbers are strictly increasing" do
      raw_events = for i <- 1..10, do: %{"type" => "message_received", "index" => i}
      context = %{session_id: "ses_123", run_id: "run_456", provider: :generic}

      {:ok, normalized_list} = EventNormalizer.normalize_batch(raw_events, context)

      sequence_numbers = Enum.map(normalized_list, & &1.sequence_number)

      # Each sequence should be exactly 1 more than previous
      sequence_numbers
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [s1, s2] ->
        assert s2 == s1 + 1, "Sequence numbers must be strictly increasing by 1"
      end)
    end

    test "event IDs are unique within a batch" do
      raw_events = for _ <- 1..100, do: %{"type" => "message_received"}
      context = %{session_id: "ses_123", run_id: "run_456", provider: :generic}

      {:ok, normalized_list} = EventNormalizer.normalize_batch(raw_events, context)

      ids = Enum.map(normalized_list, & &1.id)
      unique_ids = Enum.uniq(ids)

      assert length(ids) == length(unique_ids), "All event IDs must be unique"
    end

    test "preserves original order of events" do
      raw_events = for i <- 1..10, do: %{"type" => "message_received", "index" => i}
      context = %{session_id: "ses_123", run_id: "run_456", provider: :generic}

      {:ok, normalized_list} = EventNormalizer.normalize_batch(raw_events, context)

      # The raw data is stored in data.raw, and keys remain as strings
      indices = Enum.map(normalized_list, & &1.data[:raw]["index"])
      assert indices == Enum.to_list(1..10)
    end
  end

  describe "EventNormalizer.sort_events/1 - deterministic ordering" do
    test "sorts events by sequence_number when available" do
      events = [
        build_event(sequence_number: 3),
        build_event(sequence_number: 1),
        build_event(sequence_number: 2)
      ]

      sorted = EventNormalizer.sort_events(events)

      assert Enum.map(sorted, & &1.sequence_number) == [1, 2, 3]
    end

    test "falls back to timestamp when sequence_number is nil" do
      now = DateTime.utc_now()

      events = [
        build_event(timestamp: DateTime.add(now, 2, :second)),
        build_event(timestamp: now),
        build_event(timestamp: DateTime.add(now, 1, :second))
      ]

      sorted = EventNormalizer.sort_events(events)

      timestamps = Enum.map(sorted, & &1.timestamp)

      timestamps
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [t1, t2] ->
        assert DateTime.compare(t2, t1) in [:gt, :eq]
      end)
    end

    test "uses id as tiebreaker for same timestamp and sequence" do
      now = DateTime.utc_now()

      events = [
        build_event(id: "nevt_c", sequence_number: 1, timestamp: now),
        build_event(id: "nevt_a", sequence_number: 1, timestamp: now),
        build_event(id: "nevt_b", sequence_number: 1, timestamp: now)
      ]

      sorted = EventNormalizer.sort_events(events)

      assert Enum.map(sorted, & &1.id) == ["nevt_a", "nevt_b", "nevt_c"]
    end

    test "sorting is stable and deterministic" do
      events =
        for i <- 1..20 do
          build_event(
            sequence_number: rem(i, 5),
            id: "nevt_#{String.pad_leading("#{i}", 3, "0")}"
          )
        end

      # Sort multiple times - should always produce same result
      sorted1 = EventNormalizer.sort_events(events)
      sorted2 = EventNormalizer.sort_events(Enum.shuffle(events))
      sorted3 = EventNormalizer.sort_events(Enum.reverse(events))

      assert Enum.map(sorted1, & &1.id) == Enum.map(sorted2, & &1.id)
      assert Enum.map(sorted2, & &1.id) == Enum.map(sorted3, & &1.id)
    end
  end

  describe "EventNormalizer.filter_by_run/2" do
    test "filters events by run_id" do
      events = [
        build_event(run_id: "run_1"),
        build_event(run_id: "run_2"),
        build_event(run_id: "run_1"),
        build_event(run_id: "run_3")
      ]

      filtered = EventNormalizer.filter_by_run(events, "run_1")

      assert length(filtered) == 2
      assert Enum.all?(filtered, &(&1.run_id == "run_1"))
    end
  end

  describe "EventNormalizer.filter_by_session/2" do
    test "filters events by session_id" do
      events = [
        build_event(session_id: "ses_1"),
        build_event(session_id: "ses_2"),
        build_event(session_id: "ses_1")
      ]

      filtered = EventNormalizer.filter_by_session(events, "ses_1")

      assert length(filtered) == 2
      assert Enum.all?(filtered, &(&1.session_id == "ses_1"))
    end
  end

  describe "EventNormalizer.filter_by_type/2" do
    test "filters events by single type" do
      events = [
        build_event(type: :message_sent),
        build_event(type: :message_received),
        build_event(type: :message_sent),
        build_event(type: :tool_call_started)
      ]

      filtered = EventNormalizer.filter_by_type(events, :message_sent)

      assert length(filtered) == 2
      assert Enum.all?(filtered, &(&1.type == :message_sent))
    end

    test "filters events by list of types" do
      events = [
        build_event(type: :message_sent),
        build_event(type: :message_received),
        build_event(type: :tool_call_started),
        build_event(type: :run_completed)
      ]

      filtered = EventNormalizer.filter_by_type(events, [:message_sent, :message_received])

      assert length(filtered) == 2
      assert Enum.all?(filtered, &(&1.type in [:message_sent, :message_received]))
    end
  end

  # Helper to build test events
  defp build_event(overrides) do
    defaults = [
      id: "nevt_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}",
      type: :message_received,
      timestamp: DateTime.utc_now(),
      session_id: "ses_test",
      run_id: "run_test",
      sequence_number: nil,
      data: %{},
      metadata: %{}
    ]

    attrs = Keyword.merge(defaults, overrides) |> Map.new()

    struct!(NormalizedEvent, attrs)
  end
end
