defmodule AgentSessionManager.Core.Event do
  @moduledoc """
  Represents an event in the agent session lifecycle.

  Events are immutable records of things that happened during
  session and run execution. They provide an audit trail and
  can be used for debugging, analytics, and state reconstruction.

  ## Event Categories

  ### Session Lifecycle Events
  - `:session_created` - A new session was created
  - `:session_started` - Session execution began
  - `:session_paused` - Session was paused
  - `:session_resumed` - Session was resumed from pause
  - `:session_completed` - Session completed successfully
  - `:session_failed` - Session failed with an error
  - `:session_cancelled` - Session was cancelled

  ### Run Lifecycle Events
  - `:run_started` - A run began execution
  - `:run_completed` - A run completed successfully
  - `:run_failed` - A run failed with an error
  - `:run_cancelled` - A run was cancelled
  - `:run_timeout` - A run timed out

  ### Message Events
  - `:message_sent` - A message was sent to the agent
  - `:message_received` - A message was received from the agent
  - `:message_streamed` - A streaming message chunk was received

  ### Tool Events
  - `:tool_call_started` - A tool call began
  - `:tool_call_completed` - A tool call completed
  - `:tool_call_failed` - A tool call failed

  ### Error Events
  - `:error_occurred` - An error occurred
  - `:error_recovered` - Recovered from an error

  ### Usage Events
  - `:token_usage_updated` - Token usage was updated
  - `:turn_completed` - A conversation turn completed

  ## Usage

      # Create an event
      {:ok, event} = Event.new(%{
        type: :message_received,
        session_id: "session-123",
        run_id: "run-456",
        data: %{content: "Hello!"}
      })

      # Serialize for storage
      map = Event.to_map(event)

  """

  alias AgentSessionManager.Core.{Error, Serialization}

  # Session lifecycle events
  @session_events [
    :session_created,
    :session_started,
    :session_paused,
    :session_resumed,
    :session_completed,
    :session_failed,
    :session_cancelled
  ]

  # Run lifecycle events
  @run_events [
    :run_started,
    :run_completed,
    :run_failed,
    :run_cancelled,
    :run_timeout
  ]

  # Message events
  @message_events [
    :message_sent,
    :message_received,
    :message_streamed
  ]

  # Tool events
  @tool_events [
    :tool_call_started,
    :tool_call_completed,
    :tool_call_failed
  ]

  # Error events
  @error_events [
    :error_occurred,
    :error_recovered
  ]

  # Usage events
  @usage_events [
    :token_usage_updated,
    :turn_completed
  ]

  @all_types @session_events ++
               @run_events ++
               @message_events ++
               @tool_events ++
               @error_events ++
               @usage_events

  @type event_type ::
          :session_created
          | :session_started
          | :session_paused
          | :session_resumed
          | :session_completed
          | :session_failed
          | :session_cancelled
          | :run_started
          | :run_completed
          | :run_failed
          | :run_cancelled
          | :run_timeout
          | :message_sent
          | :message_received
          | :message_streamed
          | :tool_call_started
          | :tool_call_completed
          | :tool_call_failed
          | :error_occurred
          | :error_recovered
          | :token_usage_updated
          | :turn_completed

  @type t :: %__MODULE__{
          id: String.t() | nil,
          type: event_type() | nil,
          timestamp: DateTime.t() | nil,
          session_id: String.t() | nil,
          run_id: String.t() | nil,
          data: map(),
          metadata: map(),
          sequence_number: non_neg_integer() | nil
        }

  defstruct [
    :id,
    :type,
    :timestamp,
    :session_id,
    :run_id,
    :sequence_number,
    data: %{},
    metadata: %{}
  ]

  @doc """
  Checks if the given type is a valid event type.
  """
  @spec valid_type?(atom()) :: boolean()
  def valid_type?(type) when is_atom(type), do: type in @all_types
  def valid_type?(_), do: false

  @doc """
  Returns all valid event types.
  """
  @spec all_types() :: [event_type()]
  def all_types, do: @all_types

  @doc """
  Returns session lifecycle event types.
  """
  @spec session_events() :: [event_type()]
  def session_events, do: @session_events

  @doc """
  Returns run lifecycle event types.
  """
  @spec run_events() :: [event_type()]
  def run_events, do: @run_events

  @doc """
  Returns message event types.
  """
  @spec message_events() :: [event_type()]
  def message_events, do: @message_events

  @doc """
  Returns tool event types.
  """
  @spec tool_events() :: [event_type()]
  def tool_events, do: @tool_events

  @doc """
  Returns error event types.
  """
  @spec error_events() :: [event_type()]
  def error_events, do: @error_events

  @doc """
  Creates a new event with the given attributes.

  ## Required

  - `:type` - The event type (must be a valid event type)
  - `:session_id` - The session this event belongs to

  ## Optional

  - `:id` - Custom ID (auto-generated if not provided)
  - `:run_id` - The run this event belongs to (for run-scoped events)
  - `:data` - Event payload data
  - `:metadata` - Arbitrary metadata
  - `:sequence_number` - Sequence number for ordering

  ## Examples

      iex> Event.new(%{type: :session_created, session_id: "session-123"})
      {:ok, %Event{type: :session_created, ...}}

      iex> Event.new(%{type: :invalid_type, session_id: "session-123"})
      {:error, %Error{code: :invalid_event_type}}

  """
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, type} <- validate_type(attrs),
         {:ok, session_id} <- validate_session_id(attrs) do
      event = %__MODULE__{
        id: Map.get(attrs, :id) || generate_id(),
        type: type,
        timestamp: DateTime.utc_now(),
        session_id: session_id,
        run_id: Map.get(attrs, :run_id),
        data: Map.get(attrs, :data, %{}),
        metadata: Map.get(attrs, :metadata, %{}),
        sequence_number: Map.get(attrs, :sequence_number)
      }

      {:ok, event}
    end
  end

  @doc """
  Converts an event to a map suitable for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      "id" => event.id,
      "type" => Atom.to_string(event.type),
      "timestamp" => DateTime.to_iso8601(event.timestamp),
      "session_id" => event.session_id,
      "run_id" => event.run_id,
      "data" => Serialization.stringify_keys(event.data),
      "metadata" => Serialization.stringify_keys(event.metadata),
      "sequence_number" => event.sequence_number
    }
  end

  @doc """
  Reconstructs an event from a map.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map) when is_map(map) do
    with {:ok, id} <- get_required_string(map, "id"),
         {:ok, type} <- parse_type(map["type"]),
         {:ok, session_id} <- get_required_string(map, "session_id"),
         {:ok, timestamp} <- parse_datetime(map["timestamp"]) do
      event = %__MODULE__{
        id: id,
        type: type,
        timestamp: timestamp,
        session_id: session_id,
        run_id: map["run_id"],
        data: Serialization.atomize_keys(map["data"] || %{}),
        metadata: Serialization.atomize_keys(map["metadata"] || %{}),
        sequence_number: map["sequence_number"]
      }

      {:ok, event}
    end
  end

  def from_map(_), do: {:error, Error.new(:validation_error, "Invalid event map")}

  # Private helpers

  defp validate_type(%{type: type}) when is_atom(type) do
    if valid_type?(type) do
      {:ok, type}
    else
      {:error, Error.new(:invalid_event_type, "Invalid event type: #{inspect(type)}")}
    end
  end

  defp validate_type(_), do: {:error, Error.new(:validation_error, "type is required")}

  defp validate_session_id(%{session_id: session_id})
       when is_binary(session_id) and session_id != "" do
    {:ok, session_id}
  end

  defp validate_session_id(%{session_id: ""}),
    do: {:error, Error.new(:validation_error, "session_id cannot be empty")}

  defp validate_session_id(_),
    do: {:error, Error.new(:validation_error, "session_id is required")}

  defp generate_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> then(&"evt_#{&1}")
  end

  defp get_required_string(map, key) do
    case Map.get(map, key) do
      nil -> {:error, Error.new(:validation_error, "#{key} is required")}
      "" -> {:error, Error.new(:validation_error, "#{key} cannot be empty")}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, Error.new(:validation_error, "#{key} must be a string")}
    end
  end

  defp parse_type(nil), do: {:error, Error.new(:validation_error, "type is required")}

  defp parse_type(type) when is_binary(type) do
    atom = String.to_existing_atom(type)

    if valid_type?(atom) do
      {:ok, atom}
    else
      {:error, Error.new(:invalid_event_type, "Invalid event type: #{type}")}
    end
  rescue
    ArgumentError -> {:error, Error.new(:invalid_event_type, "Invalid event type: #{type}")}
  end

  defp parse_type(_), do: {:error, Error.new(:validation_error, "type must be a string")}

  defp parse_datetime(nil), do: {:error, Error.new(:validation_error, "timestamp is required")}

  defp parse_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> {:ok, dt}
      {:error, _} -> {:error, Error.new(:validation_error, "Invalid datetime format")}
    end
  end

  defp parse_datetime(_), do: {:error, Error.new(:validation_error, "timestamp must be a string")}
end
