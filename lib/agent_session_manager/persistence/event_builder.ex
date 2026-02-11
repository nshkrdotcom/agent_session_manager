defmodule AgentSessionManager.Persistence.EventBuilder do
  @moduledoc """
  Normalizes and validates adapter events without persisting them.
  """

  alias AgentSessionManager.Config
  alias AgentSessionManager.Core.{Error, Event, EventNormalizer}
  alias AgentSessionManager.Persistence.{EventRedactor, EventValidator}

  @type context :: %{
          required(:session_id) => String.t(),
          required(:run_id) => String.t(),
          required(:provider) => String.t(),
          optional(:correlation_id) => String.t(),
          optional(:redaction) => map()
        }

  @spec process(map(), context()) :: {:ok, Event.t()} | {:error, Error.t()}
  def process(raw_event_data, context) when is_map(raw_event_data) and is_map(context) do
    with {:ok, event} <- build_event(raw_event_data, context),
         {:ok, event} <- maybe_redact(event, context),
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
    %{
      event
      | provider: context.provider,
        correlation_id: Map.get(context, :correlation_id)
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

  defp maybe_redact(event, context) do
    config = resolve_redaction_config(context)

    if config.enabled do
      result = EventRedactor.redact(event, config)
      maybe_emit_redaction_telemetry(result, event)
      {:ok, result.event}
    else
      {:ok, event}
    end
  end

  defp resolve_redaction_config(context) do
    case Map.get(context, :redaction) do
      %{} = override ->
        Map.put_new(override, :enabled, true)

      _ ->
        %{
          enabled: Config.get(:redaction_enabled),
          patterns: Config.get(:redaction_patterns),
          replacement: Config.get(:redaction_replacement),
          deep_scan: Config.get(:redaction_deep_scan),
          scan_metadata: Config.get(:redaction_scan_metadata)
        }
    end
  end

  defp maybe_emit_redaction_telemetry(%{redaction_count: 0}, _event), do: :ok

  defp maybe_emit_redaction_telemetry(result, event) do
    :telemetry.execute(
      [:agent_session_manager, :persistence, :event_redacted],
      %{redaction_count: result.redaction_count},
      %{
        session_id: event.session_id,
        run_id: event.run_id,
        type: event.type,
        fields_redacted: result.fields_redacted
      }
    )
  end
end
