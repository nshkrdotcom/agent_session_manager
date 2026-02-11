defmodule AgentSessionManager.Core.EventStream do
  @moduledoc """
  Manages incremental consumption of normalized event streams.

  EventStream provides a cursor-based mechanism for consuming events
  incrementally, supporting both batch and streaming consumption patterns.

  ## Features

  - Cursor-based navigation for resumable consumption
  - Buffer management with configurable size limits
  - Context validation (session_id, run_id matching)
  - Enumerable support for functional operations

  ## Usage

      # Create a new stream
      {:ok, stream} = EventStream.new(%{session_id: "ses_123", run_id: "run_456"})

      # Push events
      {:ok, stream} = EventStream.push(stream, event)
      {:ok, stream} = EventStream.push_batch(stream, events)

      # Consume events
      events = EventStream.peek(stream, 5)      # Non-consuming read
      {:ok, events, stream} = EventStream.take(stream, 5)  # Consuming read

      # Get all events (sorted)
      all_events = EventStream.get_events(stream)

      # Close when done
      {:ok, stream} = EventStream.close(stream)

  """

  alias AgentSessionManager.Config
  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Core.EventNormalizer
  alias AgentSessionManager.Core.NormalizedEvent

  @type status :: :open | :closed

  @type t :: %__MODULE__{
          session_id: String.t(),
          run_id: String.t(),
          events: [NormalizedEvent.t()],
          cursor: non_neg_integer(),
          buffer_size: pos_integer(),
          status: status(),
          next_sequence: non_neg_integer()
        }

  defstruct [
    :session_id,
    :run_id,
    events: [],
    cursor: 0,
    buffer_size: Config.get(:event_buffer_size),
    status: :open,
    next_sequence: 0
  ]

  @doc """
  Creates a new event stream for the given context.

  ## Required

  - `:session_id` - The session ID for this stream
  - `:run_id` - The run ID for this stream

  ## Optional

  - `:buffer_size` - Maximum number of events to keep in memory (default: 1000)

  """
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(context) when is_map(context) do
    with {:ok, session_id} <- get_required(context, :session_id),
         {:ok, run_id} <- get_required(context, :run_id) do
      stream = %__MODULE__{
        session_id: session_id,
        run_id: run_id,
        buffer_size: Map.get(context, :buffer_size, Config.get(:event_buffer_size)),
        events: [],
        cursor: 0,
        status: :open,
        next_sequence: 0
      }

      {:ok, stream}
    end
  end

  @doc """
  Pushes a single event to the stream.

  The event must have matching session_id and run_id. If the event
  doesn't have a sequence_number, one will be assigned automatically.
  """
  @spec push(t(), NormalizedEvent.t()) :: {:ok, t()} | {:error, Error.t()}
  def push(%__MODULE__{status: :closed}, _event) do
    {:error, Error.new(:stream_closed, "Cannot push to a closed stream")}
  end

  def push(%__MODULE__{} = stream, %NormalizedEvent{} = event) do
    with :ok <- validate_context(stream, event) do
      # Assign sequence number if not present
      event =
        if event.sequence_number == nil do
          %{event | sequence_number: stream.next_sequence}
        else
          event
        end

      # Add event to stream (prepend for efficiency)
      events = [event | stream.events]

      # Trim to buffer size, keeping most recent events
      events = trim_to_buffer_size(events, stream.buffer_size)

      # Update next sequence
      next_seq = max(stream.next_sequence, event.sequence_number + 1)

      {:ok, %{stream | events: events, next_sequence: next_seq}}
    end
  end

  @doc """
  Pushes a batch of events to the stream atomically.

  All events must have matching session_id and run_id. If any event
  fails validation, the entire batch is rejected.
  """
  @spec push_batch(t(), [NormalizedEvent.t()]) :: {:ok, t()} | {:error, Error.t()}
  def push_batch(%__MODULE__{status: :closed}, _events) do
    {:error, Error.new(:stream_closed, "Cannot push to a closed stream")}
  end

  def push_batch(%__MODULE__{} = stream, events) when is_list(events) do
    # Validate all events first
    case Enum.find(events, &(validate_context(stream, &1) != :ok)) do
      nil ->
        # All events valid - push them
        Enum.reduce(events, {:ok, stream}, fn event, {:ok, acc} ->
          push(acc, event)
        end)

      invalid_event ->
        {:error,
         Error.new(
           :context_mismatch,
           "Event #{invalid_event.id} has mismatched context"
         )}
    end
  end

  @doc """
  Returns all events in the stream, sorted by sequence number.

  ## Options

  - `:from_cursor` - If true, only return events from cursor position onwards
  - `:limit` - Maximum number of events to return
  - `:type` - Filter by event type (atom or list of atoms)

  """
  @spec get_events(t(), keyword()) :: [NormalizedEvent.t()]
  def get_events(%__MODULE__{} = stream, opts \\ []) do
    events = EventNormalizer.sort_events(stream.events)

    events =
      if Keyword.get(opts, :from_cursor, false) do
        Enum.filter(events, &(&1.sequence_number >= stream.cursor))
      else
        events
      end

    events =
      case Keyword.get(opts, :type) do
        nil -> events
        type when is_atom(type) -> EventNormalizer.filter_by_type(events, type)
        types when is_list(types) -> EventNormalizer.filter_by_type(events, types)
      end

    case Keyword.get(opts, :limit) do
      nil -> events
      limit -> Enum.take(events, limit)
    end
  end

  @doc """
  Advances the cursor to the specified position.

  The cursor can only move forward, never backward.
  """
  @spec advance_cursor(t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def advance_cursor(%__MODULE__{cursor: current} = stream, position)
      when is_integer(position) and position >= current do
    {:ok, %{stream | cursor: position}}
  end

  def advance_cursor(%__MODULE__{}, position) when is_integer(position) do
    {:error, Error.new(:invalid_cursor, "Cannot move cursor backwards")}
  end

  @doc """
  Returns the next `count` events without advancing the cursor.
  """
  @spec peek(t(), non_neg_integer()) :: [NormalizedEvent.t()]
  def peek(%__MODULE__{} = stream, count) when is_integer(count) and count >= 0 do
    get_events(stream, from_cursor: true, limit: count)
  end

  @doc """
  Returns the next `count` events and advances the cursor.

  Returns `{:ok, events, updated_stream}`.
  """
  @spec take(t(), non_neg_integer()) ::
          {:ok, [NormalizedEvent.t()], t()} | {:error, Error.t()}
  def take(%__MODULE__{} = stream, count) when is_integer(count) and count >= 0 do
    events = peek(stream, count)

    new_cursor =
      case events do
        [] -> stream.cursor
        _ -> Enum.max_by(events, & &1.sequence_number).sequence_number + 1
      end

    {:ok, events, %{stream | cursor: new_cursor}}
  end

  @doc """
  Returns the total number of events in the stream.
  """
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{events: events}), do: length(events)

  @doc """
  Returns the number of unread events (from cursor to end).
  """
  @spec remaining(t()) :: non_neg_integer()
  def remaining(%__MODULE__{} = stream) do
    stream.events
    |> Enum.count(&(&1.sequence_number >= stream.cursor))
  end

  @doc """
  Closes the stream, preventing further pushes.

  The cursor is advanced to the end position.
  """
  @spec close(t()) :: {:ok, t()}
  def close(%__MODULE__{} = stream) do
    end_cursor =
      case stream.events do
        [] -> 0
        events -> Enum.max_by(events, & &1.sequence_number).sequence_number + 1
      end

    {:ok, %{stream | status: :closed, cursor: end_cursor}}
  end

  @doc """
  Returns whether the stream is closed.
  """
  @spec closed?(t()) :: boolean()
  def closed?(%__MODULE__{status: status}), do: status == :closed

  @doc """
  Returns an enumerable view of the stream's remaining events.

  This allows using Enum functions on the stream's events.
  """
  @spec to_enumerable(t()) :: Enumerable.t()
  def to_enumerable(%__MODULE__{} = stream) do
    get_events(stream, from_cursor: true)
  end

  # Private helpers

  defp get_required(context, key) do
    case Map.get(context, key) do
      nil -> {:error, Error.new(:validation_error, "#{key} is required")}
      "" -> {:error, Error.new(:validation_error, "#{key} cannot be empty")}
      value -> {:ok, value}
    end
  end

  defp validate_context(%__MODULE__{session_id: stream_session}, %NormalizedEvent{
         session_id: event_session
       })
       when stream_session != event_session do
    {:error, Error.new(:session_mismatch, "Event session_id does not match stream session_id")}
  end

  defp validate_context(%__MODULE__{run_id: stream_run}, %NormalizedEvent{run_id: event_run})
       when stream_run != event_run do
    {:error, Error.new(:run_mismatch, "Event run_id does not match stream run_id")}
  end

  defp validate_context(_stream, _event), do: :ok

  defp trim_to_buffer_size(events, buffer_size) when length(events) > buffer_size do
    # Sort by sequence to keep the most recent events
    events
    |> Enum.sort_by(& &1.sequence_number, :desc)
    |> Enum.take(buffer_size)
  end

  defp trim_to_buffer_size(events, _buffer_size), do: events
end
