defmodule AgentSessionManager.Persistence.EventValidator do
  @moduledoc """
  Validates event structure and data shapes.

  Structural validation is strict — events that fail are rejected
  and not persisted. Shape validation is advisory — warnings are
  attached to metadata but the event is still persisted.

  ## Two-Tier Validation

  1. **Structural** (`validate_structural/1`): Checks required fields
     and types. Rejects on failure.

  2. **Shape** (`validate_shape/1`): Checks event-type-specific data
     field expectations. Returns warnings but does not reject.
  """

  alias AgentSessionManager.Core.{Error, Event}

  @doc """
  Validates required fields and types on an Event struct.

  Returns `:ok` if all structural requirements are met, or
  `{:error, Error.t()}` if a required field is missing or
  has an invalid type.
  """
  @spec validate_structural(Event.t()) :: :ok | {:error, Error.t()}
  def validate_structural(%Event{} = event) do
    with :ok <- validate_present(:type, event.type),
         :ok <- validate_present(:session_id, event.session_id),
         :ok <- validate_present(:timestamp, event.timestamp),
         :ok <- validate_valid_type(event.type) do
      validate_data_is_map(event.data)
    end
  end

  @doc """
  Validates the data shape for the event type.

  Returns a list of warning strings. An empty list means the
  data matches the expected shape for this event type. Event
  types without shape rules pass unconditionally.
  """
  @spec validate_shape(Event.t()) :: [String.t()]
  def validate_shape(%Event{type: type, data: data}) do
    case shape_rules(type) do
      nil -> []
      rules -> Enum.flat_map(rules, &check_rule(&1, data))
    end
  end

  # ============================================================================
  # Structural validation helpers
  # ============================================================================

  defp validate_present(field, nil),
    do: {:error, Error.new(:validation_error, "#{field} is required")}

  defp validate_present(_field, _value), do: :ok

  defp validate_valid_type(type) when is_atom(type) do
    if Event.valid_type?(type) do
      :ok
    else
      {:error, Error.new(:invalid_event_type, "Invalid event type: #{inspect(type)}")}
    end
  end

  defp validate_valid_type(type),
    do: {:error, Error.new(:validation_error, "type must be an atom, got: #{inspect(type)}")}

  defp validate_data_is_map(data) when is_map(data), do: :ok
  defp validate_data_is_map(nil), do: :ok

  defp validate_data_is_map(data),
    do: {:error, Error.new(:validation_error, "data must be a map, got: #{inspect(data)}")}

  # ============================================================================
  # Shape validation rules
  # ============================================================================

  @shape_rules %{
    message_received: [
      {:required, :content, :string},
      {:required, :role, :string}
    ],
    message_streamed: [
      {:required, :content, :string}
    ],
    tool_call_started: [
      {:required, :tool_name, :string}
    ],
    tool_call_completed: [
      {:required, :tool_name, :string}
    ],
    tool_call_failed: [
      {:required, :tool_name, :string}
    ],
    token_usage_updated: [
      {:required, :input_tokens, :integer},
      {:required, :output_tokens, :integer}
    ],
    run_completed: [
      {:required, :stop_reason, :string}
    ],
    error_occurred: [
      {:required, :error_message, :string}
    ],
    policy_violation: [
      {:required, :policy, :string},
      {:required, :kind, :string}
    ],
    tool_approval_requested: [
      {:required, :tool_name, :string},
      {:required, :policy_name, :string}
    ],
    tool_approval_granted: [
      {:required, :tool_name, :string}
    ],
    tool_approval_denied: [
      {:required, :tool_name, :string}
    ]
  }

  defp shape_rules(type), do: Map.get(@shape_rules, type)

  defp check_rule({:required, field, expected_type}, data) do
    str_field = to_string(field)

    value = Map.get(data, field) || Map.get(data, str_field)

    cond do
      is_nil(value) ->
        ["missing required field '#{field}' for shape validation"]

      not type_matches?(value, expected_type) ->
        ["field '#{field}' expected #{expected_type}, got #{inspect(value)}"]

      true ->
        []
    end
  end

  defp type_matches?(value, :string) when is_binary(value), do: true
  defp type_matches?(value, :integer) when is_integer(value), do: true
  defp type_matches?(value, :map) when is_map(value), do: true
  defp type_matches?(value, :list) when is_list(value), do: true
  defp type_matches?(value, :boolean) when is_boolean(value), do: true
  defp type_matches?(value, :number) when is_number(value), do: true
  defp type_matches?(_value, _type), do: false
end
