defmodule AgentSessionManager.Core.NormalizedEvent do
  @moduledoc """
  Represents a normalized event in the event stream.

  NormalizedEvent is the canonical representation that all provider-specific
  events are transformed into. This ensures consistent handling across
  different AI providers (Anthropic, OpenAI, etc.) and provides strong
  ordering guarantees.

  ## Required Fields

  - `id` - Unique event identifier (auto-generated if not provided)
  - `type` - Event type (must be a valid event type)
  - `timestamp` - When the event occurred
  - `session_id` - The session this event belongs to
  - `run_id` - The run this event belongs to

  ## Ordering Fields

  - `sequence_number` - Monotonically increasing number for ordering
  - `parent_event_id` - Optional reference to a parent event (for causal ordering)

  ## Source Tracking

  - `provider` - The source provider (:anthropic, :openai, :generic, etc.)
  - `provider_event_id` - Original event ID from the provider

  ## Usage

      # Create a normalized event
      {:ok, event} = NormalizedEvent.new(%{
        type: :message_received,
        session_id: "ses_123",
        run_id: "run_456",
        data: %{content: "Hello!"},
        provider: :anthropic
      })

      # Serialize for storage/transmission
      map = NormalizedEvent.to_map(event)

      # Reconstruct from storage
      {:ok, restored} = NormalizedEvent.from_map(map)

  """

  alias AgentSessionManager.Core.{Error, Event, Serialization}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          type: Event.event_type() | nil,
          timestamp: DateTime.t() | nil,
          session_id: String.t() | nil,
          run_id: String.t() | nil,
          sequence_number: non_neg_integer() | nil,
          parent_event_id: String.t() | nil,
          data: map(),
          metadata: map(),
          provider: atom() | nil,
          provider_event_id: String.t() | nil
        }

  defstruct [
    :id,
    :type,
    :timestamp,
    :session_id,
    :run_id,
    :sequence_number,
    :parent_event_id,
    :provider,
    :provider_event_id,
    data: %{},
    metadata: %{}
  ]

  @doc """
  Creates a new normalized event with the given attributes.

  ## Required

  - `:type` - The event type (must be a valid event type)
  - `:session_id` - The session this event belongs to
  - `:run_id` - The run this event belongs to

  ## Optional

  - `:id` - Custom ID (auto-generated if not provided)
  - `:sequence_number` - Sequence number for ordering
  - `:parent_event_id` - Parent event ID for causal ordering
  - `:data` - Event payload data
  - `:metadata` - Arbitrary metadata
  - `:provider` - Source provider atom
  - `:provider_event_id` - Original provider event ID

  ## Examples

      iex> NormalizedEvent.new(%{type: :message_received, session_id: "ses_123", run_id: "run_456"})
      {:ok, %NormalizedEvent{type: :message_received, ...}}

      iex> NormalizedEvent.new(%{type: :invalid_type, session_id: "ses_123", run_id: "run_456"})
      {:error, %Error{code: :invalid_event_type}}

  """
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, type} <- validate_type(attrs),
         {:ok, session_id} <- validate_session_id(attrs),
         {:ok, run_id} <- validate_run_id(attrs) do
      event = %__MODULE__{
        id: Map.get(attrs, :id) || generate_id(),
        type: type,
        timestamp: DateTime.utc_now(),
        session_id: session_id,
        run_id: run_id,
        sequence_number: Map.get(attrs, :sequence_number),
        parent_event_id: Map.get(attrs, :parent_event_id),
        data: Map.get(attrs, :data, %{}),
        metadata: Map.get(attrs, :metadata, %{}),
        provider: Map.get(attrs, :provider),
        provider_event_id: Map.get(attrs, :provider_event_id)
      }

      {:ok, event}
    end
  end

  @doc """
  Checks if a normalized event is valid (has all required fields populated).
  """
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = event) do
    event.id != nil and
      event.type != nil and
      event.timestamp != nil and
      event.session_id != nil and event.session_id != "" and
      event.run_id != nil and event.run_id != "" and
      Event.valid_type?(event.type)
  end

  def valid?(_), do: false

  @doc """
  Checks if two events belong to the same context (session and run).
  """
  @spec same_context?(t(), t()) :: boolean()
  def same_context?(%__MODULE__{} = event1, %__MODULE__{} = event2) do
    event1.session_id == event2.session_id and event1.run_id == event2.run_id
  end

  @doc """
  Converts a normalized event to a map suitable for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      "id" => event.id,
      "type" => Atom.to_string(event.type),
      "timestamp" => DateTime.to_iso8601(event.timestamp),
      "session_id" => event.session_id,
      "run_id" => event.run_id,
      "sequence_number" => event.sequence_number,
      "parent_event_id" => event.parent_event_id,
      "data" => Serialization.stringify_keys(event.data),
      "metadata" => Serialization.stringify_keys(event.metadata),
      "provider" => maybe_to_string(event.provider),
      "provider_event_id" => event.provider_event_id
    }
  end

  @doc """
  Reconstructs a normalized event from a map.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map) when is_map(map) do
    with {:ok, id} <- get_required_string(map, "id"),
         {:ok, type} <- parse_type(map["type"]),
         {:ok, session_id} <- get_required_string(map, "session_id"),
         {:ok, run_id} <- get_required_string(map, "run_id"),
         {:ok, timestamp} <- parse_datetime(map["timestamp"]) do
      event = %__MODULE__{
        id: id,
        type: type,
        timestamp: timestamp,
        session_id: session_id,
        run_id: run_id,
        sequence_number: map["sequence_number"],
        parent_event_id: map["parent_event_id"],
        data: Serialization.atomize_keys(map["data"] || %{}),
        metadata: Serialization.atomize_keys(map["metadata"] || %{}),
        provider: parse_provider(map["provider"]),
        provider_event_id: map["provider_event_id"]
      }

      {:ok, event}
    end
  end

  def from_map(_), do: {:error, Error.new(:validation_error, "Invalid event map")}

  # Private helpers

  defp validate_type(%{type: type}) when is_atom(type) do
    if Event.valid_type?(type) do
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

  defp validate_run_id(%{run_id: run_id})
       when is_binary(run_id) and run_id != "" do
    {:ok, run_id}
  end

  defp validate_run_id(%{run_id: ""}),
    do: {:error, Error.new(:validation_error, "run_id cannot be empty")}

  defp validate_run_id(_),
    do: {:error, Error.new(:validation_error, "run_id is required")}

  defp generate_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> then(&"nevt_#{&1}")
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

    if Event.valid_type?(atom) do
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

  defp parse_provider(nil), do: nil

  defp parse_provider(provider) when is_binary(provider) do
    case Serialization.maybe_to_existing_atom(provider) do
      atom when is_atom(atom) -> atom
      _ -> :generic
    end
  end

  defp parse_provider(provider) when is_atom(provider), do: provider

  defp maybe_to_string(nil), do: nil
  defp maybe_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)
end
