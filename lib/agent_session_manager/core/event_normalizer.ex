defmodule AgentSessionManager.Core.EventNormalizer do
  @moduledoc """
  Event normalization pipeline for transforming provider events into normalized events.

  This module provides adapter helpers to map provider-specific events into
  the canonical NormalizedEvent format, ensuring consistent handling across
  different AI providers.

  ## Responsibilities

  - Transform raw provider events into NormalizedEvent structs
  - Assign sequence numbers for ordering
  - Map provider-specific event types to canonical types
  - Provide sorting and filtering utilities

  ## Event Type Mapping

  The normalizer maps common provider event patterns to canonical types:

  - User messages -> :message_sent
  - Assistant messages -> :message_received
  - Streaming chunks -> :message_streamed
  - Tool invocations -> :tool_call_started/:tool_call_completed/:tool_call_failed
  - Run lifecycle -> :run_started/:run_completed/:run_failed

  ## Usage

      # Normalize a single event
      {:ok, normalized} = EventNormalizer.normalize(raw_event, context)

      # Normalize a batch with automatic sequencing
      {:ok, events} = EventNormalizer.normalize_batch(raw_events, context)

      # Sort events deterministically
      sorted = EventNormalizer.sort_events(events)

  """

  alias AgentSessionManager.Core.{Error, Event, NormalizedEvent, Serialization}

  @doc """
  Resolves a raw event type (string or atom) to a canonical event atom type.
  Canonical event names are the values in `Event.event_types/0`.

  Returns `:error_occurred` for unrecognized or unsupported types.

  ## Examples

      iex> EventNormalizer.resolve_type("run_started")
      :run_started

      iex> EventNormalizer.resolve_type(:run_started)
      :run_started

      iex> EventNormalizer.resolve_type("unknown_type")
      :error_occurred

  """
  @spec resolve_type(atom() | String.t() | term()) :: atom()
  def resolve_type(type) when is_atom(type) do
    if Event.valid_type?(type), do: type, else: :error_occurred
  end

  def resolve_type(type) when is_binary(type) do
    case Serialization.maybe_to_existing_atom(type) do
      atom when is_atom(atom) ->
        if Event.valid_type?(atom), do: atom, else: :error_occurred

      _ ->
        :error_occurred
    end
  end

  def resolve_type(_), do: :error_occurred

  @doc """
  Normalizes a raw event map into a NormalizedEvent.

  ## Parameters

  - `raw_event` - The raw event data from a provider
  - `context` - Context map with required `:session_id`, `:run_id`, and optional `:provider`

  ## Examples

      iex> EventNormalizer.normalize(%{"type" => "message_received"}, %{session_id: "s1", run_id: "r1"})
      {:ok, %NormalizedEvent{type: :message_received, ...}}

  """
  @spec normalize(map(), map()) :: {:ok, NormalizedEvent.t()} | {:error, Error.t()}
  def normalize(raw_event, context) when is_map(raw_event) and is_map(context) do
    with {:ok, session_id} <- get_required(context, :session_id),
         {:ok, run_id} <- get_required(context, :run_id) do
      type = determine_event_type(raw_event)
      provider = Map.get(context, :provider, :generic)
      provider_event_id = extract_provider_event_id(raw_event)

      attrs = %{
        type: type,
        session_id: session_id,
        run_id: run_id,
        data: build_event_data(raw_event, type),
        metadata: extract_metadata(raw_event),
        provider: provider,
        provider_event_id: provider_event_id,
        sequence_number: Map.get(context, :sequence_number)
      }

      NormalizedEvent.new(attrs)
    end
  end

  def normalize(_, _), do: {:error, Error.new(:validation_error, "Invalid raw event or context")}

  @doc """
  Normalizes a batch of raw events with automatic sequence numbering.

  Events are processed in order and assigned sequential sequence numbers
  starting from the offset (default 0).

  Returns `{:ok, events}` if all succeed, or `{:error, %{errors: [...], successful: [...]}}`
  if any fail.

  ## Options in context

  - `:sequence_offset` - Starting sequence number (default: 0)

  """
  @spec normalize_batch([map()], map()) ::
          {:ok, [NormalizedEvent.t()]} | {:error, %{errors: list(), successful: list()}}
  def normalize_batch(raw_events, context) when is_list(raw_events) and is_map(context) do
    offset = Map.get(context, :sequence_offset, 0)

    {successful, errors} =
      raw_events
      |> Enum.with_index(offset)
      |> Enum.reduce({[], []}, fn {raw_event, seq}, {success_acc, error_acc} ->
        ctx = Map.put(context, :sequence_number, seq)

        case normalize(raw_event, ctx) do
          {:ok, event} -> {[event | success_acc], error_acc}
          {:error, error} -> {success_acc, [{seq, raw_event, error} | error_acc]}
        end
      end)

    case errors do
      [] ->
        {:ok, Enum.reverse(successful)}

      _ ->
        {:error, %{errors: Enum.reverse(errors), successful: Enum.reverse(successful)}}
    end
  end

  @doc """
  Sorts events in deterministic order.

  Sorting priority:
  1. `sequence_number` (ascending, nil values last)
  2. `timestamp` (ascending)
  3. `id` (lexicographic, as tiebreaker)

  This ensures stable, reproducible ordering regardless of input order.
  """
  @spec sort_events([NormalizedEvent.t()]) :: [NormalizedEvent.t()]
  def sort_events(events) when is_list(events) do
    Enum.sort(events, &compare_events/2)
  end

  @doc """
  Filters events by run_id.
  """
  @spec filter_by_run([NormalizedEvent.t()], String.t()) :: [NormalizedEvent.t()]
  def filter_by_run(events, run_id) when is_list(events) and is_binary(run_id) do
    Enum.filter(events, &(&1.run_id == run_id))
  end

  @doc """
  Filters events by session_id.
  """
  @spec filter_by_session([NormalizedEvent.t()], String.t()) :: [NormalizedEvent.t()]
  def filter_by_session(events, session_id) when is_list(events) and is_binary(session_id) do
    Enum.filter(events, &(&1.session_id == session_id))
  end

  @doc """
  Filters events by type or list of types.
  """
  @spec filter_by_type([NormalizedEvent.t()], atom() | [atom()]) :: [NormalizedEvent.t()]
  def filter_by_type(events, type) when is_list(events) and is_atom(type) do
    Enum.filter(events, &(&1.type == type))
  end

  def filter_by_type(events, types) when is_list(events) and is_list(types) do
    type_set = MapSet.new(types)
    Enum.filter(events, &MapSet.member?(type_set, &1.type))
  end

  # Private helpers

  defp get_required(context, key) do
    case Map.get(context, key) do
      nil -> {:error, Error.new(:validation_error, "#{key} is required in context")}
      "" -> {:error, Error.new(:validation_error, "#{key} cannot be empty")}
      value -> {:ok, value}
    end
  end

  defp determine_event_type(raw_event) do
    raw_event
    |> get_raw_type()
    |> resolve_type()
  end

  defp get_raw_type(raw_event) do
    raw_event["type"] || raw_event[:type] || ""
  end

  defp build_event_data(raw_event, type) do
    base_data = %{
      raw: raw_event
    }

    # Extract commonly useful fields
    content = raw_event["content"] || raw_event[:content]
    delta = raw_event["delta"] || raw_event[:delta]
    role = raw_event["role"] || raw_event[:role]

    tool_name =
      raw_event["tool_name"] || raw_event[:tool_name] || raw_event["name"] || raw_event[:name]

    tool_input = raw_event["tool_input"] || raw_event[:tool_input]
    tool_output = raw_event["tool_output"] || raw_event[:tool_output]

    base_data
    |> maybe_put(:content, content)
    |> maybe_put(:delta, delta)
    |> maybe_put(:role, role)
    |> maybe_put(:tool_name, tool_name)
    |> maybe_put(:tool_input, tool_input)
    |> maybe_put(:tool_output, tool_output)
    |> maybe_put_original_type(raw_event, type)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_original_type(map, raw_event, :error_occurred) do
    original_type = get_raw_type(raw_event)

    if original_type != "" do
      Map.put(map, :original_type, original_type)
    else
      map
    end
  end

  defp maybe_put_original_type(map, _raw_event, _type), do: map

  defp extract_metadata(raw_event) do
    metadata = raw_event["metadata"] || raw_event[:metadata] || %{}

    # Add any additional tracking fields
    model = raw_event["model"] || raw_event[:model]
    stop_reason = raw_event["stop_reason"] || raw_event[:stop_reason]

    metadata
    |> maybe_put(:model, model)
    |> maybe_put(:stop_reason, stop_reason)
  end

  defp extract_provider_event_id(raw_event) do
    raw_event["id"] || raw_event[:id] || raw_event["message_id"] || raw_event[:message_id]
  end

  defp compare_events(e1, e2) do
    case {e1.sequence_number, e2.sequence_number} do
      {nil, nil} -> compare_by_timestamp_then_id(e1, e2)
      # nil sequence numbers sort last
      {nil, _} -> false
      {_, nil} -> true
      {s1, s2} when s1 != s2 -> s1 < s2
      _ -> compare_by_timestamp_then_id(e1, e2)
    end
  end

  defp compare_by_timestamp_then_id(e1, e2) do
    case DateTime.compare(e1.timestamp, e2.timestamp) do
      :lt -> true
      :gt -> false
      :eq -> e1.id <= e2.id
    end
  end
end
