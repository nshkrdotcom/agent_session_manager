defmodule AgentSessionManager.Persistence.EventBuilder do
  @moduledoc """
  Normalizes and validates adapter events without persisting them.
  """

  alias AgentSessionManager.Core.{Error, Event, EventNormalizer}
  alias AgentSessionManager.Persistence.EventValidator

  @type context :: %{
          required(:session_id) => String.t(),
          required(:run_id) => String.t(),
          required(:provider) => String.t(),
          optional(:correlation_id) => String.t()
        }

  @spec process(map(), context()) :: {:ok, Event.t()} | {:error, Error.t()}
  def process(raw_event_data, context) when is_map(raw_event_data) and is_map(context) do
    with {:ok, event} <- build_event(raw_event_data, context),
         event <- enrich(event, context) do
      validate(event)
    end
  end

  defp build_event(raw_event_data, context) do
    type = normalize_type(raw_event_data)
    data = ensure_map(Map.get(raw_event_data, :data, %{}))
    metadata = ensure_map(Map.get(raw_event_data, :metadata, %{}))

    attrs = %{
      type: type,
      session_id: context.session_id,
      run_id: context.run_id,
      data: data,
      metadata: metadata,
      provider: context.provider,
      correlation_id: Map.get(context, :correlation_id)
    }

    case Event.new(attrs) do
      {:ok, event} ->
        {:ok, apply_adapter_timestamp(event, raw_event_data)}

      {:error, _} = error ->
        error
    end
  end

  defp normalize_type(raw_event_data) do
    raw_type = Map.get(raw_event_data, :type)
    resolved = EventNormalizer.resolve_type(raw_type)

    if Event.valid_type?(resolved), do: resolved, else: :error_occurred
  end

  defp apply_adapter_timestamp(event, raw_event_data) do
    case Map.get(raw_event_data, :timestamp) do
      %DateTime{} = ts -> %{event | timestamp: ts}
      _ -> event
    end
  end

  defp enrich(event, context) do
    enriched_metadata = Map.put(event.metadata, :provider, context.provider)

    %{
      event
      | provider: context.provider,
        correlation_id: Map.get(context, :correlation_id),
        metadata: enriched_metadata
    }
  end

  defp validate(event) do
    with :ok <- EventValidator.validate_structural(event) do
      warnings = EventValidator.validate_shape(event)

      event =
        if warnings != [] do
          updated_metadata = Map.put(event.metadata, :_validation_warnings, warnings)
          %{event | metadata: updated_metadata}
        else
          event
        end

      {:ok, event}
    end
  end

  defp ensure_map(nil), do: %{}
  defp ensure_map(m) when is_map(m), do: m
  defp ensure_map(_), do: %{}
end
