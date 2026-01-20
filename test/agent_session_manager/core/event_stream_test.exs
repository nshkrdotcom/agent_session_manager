defmodule AgentSessionManager.Core.EventStreamTest do
  @moduledoc """
  Tests for incremental event stream consumption.

  Following TDD: these tests specify the EventStream behavior for
  consuming normalized events incrementally.
  """
  use ExUnit.Case, async: true

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Core.EventStream
  alias AgentSessionManager.Core.NormalizedEvent

  describe "EventStream.new/1 - stream creation" do
    test "creates a new event stream with context" do
      context = %{session_id: "ses_123", run_id: "run_456"}

      assert {:ok, stream} = EventStream.new(context)

      assert stream.session_id == "ses_123"
      assert stream.run_id == "run_456"
      assert stream.events == []
      assert stream.cursor == 0
      assert stream.status == :open
    end

    test "requires session_id" do
      assert {:error, %Error{code: :validation_error}} =
               EventStream.new(%{run_id: "run_456"})
    end

    test "requires run_id" do
      assert {:error, %Error{code: :validation_error}} =
               EventStream.new(%{session_id: "ses_123"})
    end

    test "initializes with optional buffer_size" do
      {:ok, stream} =
        EventStream.new(%{
          session_id: "ses_123",
          run_id: "run_456",
          buffer_size: 100
        })

      assert stream.buffer_size == 100
    end

    test "has default buffer_size" do
      {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})

      assert stream.buffer_size == 1000
    end
  end

  describe "EventStream.push/2 - adding events" do
    test "adds a single event to the stream" do
      {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})
      event = build_event(session_id: "ses_123", run_id: "run_456")

      {:ok, updated} = EventStream.push(stream, event)

      assert length(updated.events) == 1
      pushed_event = hd(updated.events)
      # The event ID is preserved, sequence_number may be assigned
      assert pushed_event.id == event.id
      assert pushed_event.session_id == event.session_id
      assert pushed_event.run_id == event.run_id
    end

    test "assigns sequence number if not present" do
      {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})
      event = build_event(session_id: "ses_123", run_id: "run_456", sequence_number: nil)

      {:ok, updated} = EventStream.push(stream, event)

      pushed_event = hd(updated.events)
      assert pushed_event.sequence_number == 0
    end

    test "increments sequence numbers for subsequent events" do
      {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})

      events =
        for _ <- 1..5 do
          build_event(session_id: "ses_123", run_id: "run_456", sequence_number: nil)
        end

      final_stream =
        Enum.reduce(events, stream, fn event, acc ->
          {:ok, updated} = EventStream.push(acc, event)
          updated
        end)

      sequence_numbers = Enum.map(final_stream.events, & &1.sequence_number)
      # Prepended, so reversed order
      assert sequence_numbers == [4, 3, 2, 1, 0]
    end

    test "rejects events with mismatched session_id" do
      {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})
      event = build_event(session_id: "ses_wrong", run_id: "run_456")

      assert {:error, %Error{code: :session_mismatch}} = EventStream.push(stream, event)
    end

    test "rejects events with mismatched run_id" do
      {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})
      event = build_event(session_id: "ses_123", run_id: "run_wrong")

      assert {:error, %Error{code: :run_mismatch}} = EventStream.push(stream, event)
    end

    test "rejects events on closed stream" do
      {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})
      {:ok, closed} = EventStream.close(stream)
      event = build_event(session_id: "ses_123", run_id: "run_456")

      assert {:error, %Error{code: :stream_closed}} = EventStream.push(closed, event)
    end

    test "enforces buffer size limit" do
      {:ok, stream} =
        EventStream.new(%{
          session_id: "ses_123",
          run_id: "run_456",
          buffer_size: 3
        })

      events =
        for i <- 1..5 do
          build_event(session_id: "ses_123", run_id: "run_456", sequence_number: i)
        end

      final_stream =
        Enum.reduce(events, stream, fn event, acc ->
          {:ok, updated} = EventStream.push(acc, event)
          updated
        end)

      # Should only keep the 3 most recent events
      assert length(final_stream.events) == 3
      # Most recent events are kept
      sequence_numbers = Enum.map(final_stream.events, & &1.sequence_number) |> Enum.sort()
      assert sequence_numbers == [3, 4, 5]
    end
  end

  describe "EventStream.push_batch/2 - batch adding" do
    test "adds multiple events atomically" do
      {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})

      events =
        for i <- 1..3 do
          build_event(session_id: "ses_123", run_id: "run_456", sequence_number: i)
        end

      {:ok, updated} = EventStream.push_batch(stream, events)

      assert length(updated.events) == 3
    end

    test "preserves event order in batch" do
      {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})

      events =
        for i <- 1..3 do
          build_event(
            session_id: "ses_123",
            run_id: "run_456",
            sequence_number: i,
            data: %{index: i}
          )
        end

      {:ok, updated} = EventStream.push_batch(stream, events)

      # Events should be in order when retrieved
      sorted = EventStream.get_events(updated)
      indices = Enum.map(sorted, & &1.data[:index])
      assert indices == [1, 2, 3]
    end

    test "rejects batch if any event has wrong context" do
      {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})

      events = [
        build_event(session_id: "ses_123", run_id: "run_456"),
        build_event(session_id: "ses_wrong", run_id: "run_456"),
        build_event(session_id: "ses_123", run_id: "run_456")
      ]

      assert {:error, %Error{}} = EventStream.push_batch(stream, events)
    end
  end

  describe "EventStream.get_events/2 - retrieval" do
    test "returns all events sorted by sequence" do
      {:ok, stream} = build_stream_with_events(5)

      events = EventStream.get_events(stream)

      assert length(events) == 5
      sequence_numbers = Enum.map(events, & &1.sequence_number)
      assert sequence_numbers == Enum.sort(sequence_numbers)
    end

    test "returns events after cursor position" do
      {:ok, stream} = build_stream_with_events(10)
      stream = %{stream | cursor: 5}

      events = EventStream.get_events(stream, from_cursor: true)

      # Should only get events with sequence >= 5
      assert Enum.all?(events, &(&1.sequence_number >= 5))
    end

    test "limits number of returned events" do
      {:ok, stream} = build_stream_with_events(10)

      events = EventStream.get_events(stream, limit: 3)

      assert length(events) == 3
    end

    test "filters by event type" do
      {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})

      events = [
        build_event(
          session_id: "ses_123",
          run_id: "run_456",
          type: :message_sent,
          sequence_number: 1
        ),
        build_event(
          session_id: "ses_123",
          run_id: "run_456",
          type: :message_received,
          sequence_number: 2
        ),
        build_event(
          session_id: "ses_123",
          run_id: "run_456",
          type: :message_sent,
          sequence_number: 3
        )
      ]

      {:ok, stream} = EventStream.push_batch(stream, events)

      filtered = EventStream.get_events(stream, type: :message_sent)

      assert length(filtered) == 2
      assert Enum.all?(filtered, &(&1.type == :message_sent))
    end
  end

  describe "EventStream.advance_cursor/2 - cursor management" do
    test "advances cursor to specified position" do
      {:ok, stream} = build_stream_with_events(10)

      {:ok, updated} = EventStream.advance_cursor(stream, 5)

      assert updated.cursor == 5
    end

    test "cannot move cursor backwards" do
      {:ok, stream} = build_stream_with_events(10)
      {:ok, stream} = EventStream.advance_cursor(stream, 5)

      assert {:error, %Error{code: :invalid_cursor}} = EventStream.advance_cursor(stream, 3)
    end

    test "advances cursor to end on close" do
      {:ok, stream} = build_stream_with_events(10)

      {:ok, closed} = EventStream.close(stream)

      # At end
      assert closed.cursor == 10
      assert closed.status == :closed
    end
  end

  describe "EventStream.peek/2 - non-consuming read" do
    test "returns next events without advancing cursor" do
      {:ok, stream} = build_stream_with_events(5)

      events1 = EventStream.peek(stream, 2)
      events2 = EventStream.peek(stream, 2)

      assert events1 == events2
      assert length(events1) == 2
    end

    test "respects cursor position" do
      {:ok, stream} = build_stream_with_events(10)
      {:ok, stream} = EventStream.advance_cursor(stream, 5)

      events = EventStream.peek(stream, 3)

      assert length(events) == 3
      assert Enum.all?(events, &(&1.sequence_number >= 5))
    end
  end

  describe "EventStream.take/2 - consuming read" do
    test "returns events and advances cursor" do
      {:ok, stream} = build_stream_with_events(5)

      {:ok, events, updated} = EventStream.take(stream, 2)

      assert length(events) == 2
      assert updated.cursor == 2
    end

    test "subsequent takes return different events" do
      {:ok, stream} = build_stream_with_events(10)

      {:ok, events1, stream} = EventStream.take(stream, 3)
      {:ok, events2, stream} = EventStream.take(stream, 3)
      {:ok, events3, _stream} = EventStream.take(stream, 3)

      ids1 = Enum.map(events1, & &1.id) |> MapSet.new()
      ids2 = Enum.map(events2, & &1.id) |> MapSet.new()
      ids3 = Enum.map(events3, & &1.id) |> MapSet.new()

      assert MapSet.disjoint?(ids1, ids2)
      assert MapSet.disjoint?(ids2, ids3)
      assert MapSet.disjoint?(ids1, ids3)
    end

    test "returns empty list when no more events" do
      {:ok, stream} = build_stream_with_events(3)

      {:ok, _events, stream} = EventStream.take(stream, 3)
      {:ok, events, _stream} = EventStream.take(stream, 3)

      assert events == []
    end
  end

  describe "EventStream.count/1 - statistics" do
    test "returns total event count" do
      {:ok, stream} = build_stream_with_events(7)

      assert EventStream.count(stream) == 7
    end

    test "remaining/1 returns unread event count" do
      {:ok, stream} = build_stream_with_events(10)
      {:ok, stream} = EventStream.advance_cursor(stream, 3)

      assert EventStream.remaining(stream) == 7
    end
  end

  describe "EventStream.close/1 - stream lifecycle" do
    test "marks stream as closed" do
      {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})

      {:ok, closed} = EventStream.close(stream)

      assert closed.status == :closed
    end

    test "closed?/1 returns stream status" do
      {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})

      refute EventStream.closed?(stream)

      {:ok, closed} = EventStream.close(stream)

      assert EventStream.closed?(closed)
    end

    test "allows reading from closed stream" do
      {:ok, stream} = build_stream_with_events(5)
      {:ok, closed} = EventStream.close(stream)

      # Reading should still work
      events = EventStream.get_events(closed)
      assert length(events) == 5
    end
  end

  describe "EventStream.to_enumerable/1 - Enumerable protocol support" do
    test "allows Enum operations on stream" do
      {:ok, stream} = build_stream_with_events(5)

      # Should work with Enum functions
      enumerable = EventStream.to_enumerable(stream)

      count = Enum.count(enumerable)
      assert count == 5

      types = Enum.map(enumerable, & &1.type)
      assert length(types) == 5
    end

    test "enumerable respects cursor position" do
      {:ok, stream} = build_stream_with_events(10)
      {:ok, stream} = EventStream.advance_cursor(stream, 5)

      enumerable = EventStream.to_enumerable(stream)

      count = Enum.count(enumerable)
      # Only remaining events
      assert count == 5
    end
  end

  # Helper functions

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

  defp build_stream_with_events(count) do
    {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})

    events =
      for i <- 0..(count - 1) do
        build_event(
          session_id: "ses_123",
          run_id: "run_456",
          sequence_number: i,
          data: %{index: i}
        )
      end

    EventStream.push_batch(stream, events)
  end
end
