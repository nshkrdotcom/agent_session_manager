defmodule AgentSessionManager.Persistence.EventPipeline do
  @moduledoc """
  Validates, enriches, and persists events from provider adapters.

  Sits between the adapter event callback and the SessionStore,
  ensuring all persisted events have consistent structure,
  provider identity, and validated data shapes.

  ## Processing Steps

  1. **Build** — Normalize event type and construct an `Event` struct
  2. **Enrich** — Set `provider` and `correlation_id` from pipeline context
  3. **Validate** — Structural validation (strict) and shape validation (warnings)
  4. **Persist** — Append event with atomic sequence assignment

  ## Usage

      context = %{
        session_id: "ses_123",
        run_id: "run_456",
        provider: "claude"
      }

      {:ok, event} = EventPipeline.process(store, raw_event_data, context)

  """

  alias AgentSessionManager.Core.{Error, Event, EventNormalizer}
  alias AgentSessionManager.Persistence.EventValidator
  alias AgentSessionManager.Ports.SessionStore

  @type context :: %{
          required(:session_id) => String.t(),
          required(:run_id) => String.t(),
          required(:provider) => String.t(),
          optional(:correlation_id) => String.t()
        }

  @doc """
  Process a raw event from a provider adapter.

  Normalizes the event type, builds an Event struct with enriched
  fields, validates the data shape, and persists with atomic
  sequence assignment.

  Returns the persisted event with `sequence_number` populated.
  """
  @spec process(SessionStore.store(), map(), context()) ::
          {:ok, Event.t()} | {:error, Error.t()}
  def process(store, raw_event_data, context) do
    with {:ok, event} <- build_event(raw_event_data, context),
         event <- enrich(event, context),
         {:ok, event} <- validate(event),
         {:ok, persisted} <- persist(store, event) do
      emit_persisted_telemetry(persisted, context)
      {:ok, persisted}
    else
      {:error, %Error{} = error} ->
        emit_rejected_telemetry(context, error)
        {:error, error}
    end
  end

  @doc """
  Process a batch of events.

  All events are validated first. If any fail structural validation,
  the entire batch is rejected. Shape warnings are attached but
  do not reject.
  """
  @spec process_batch(SessionStore.store(), [map()], context()) ::
          {:ok, [Event.t()]} | {:error, Error.t()}
  def process_batch(store, raw_events, context) do
    results =
      Enum.reduce_while(raw_events, {:ok, []}, fn raw, {:ok, acc} ->
        case process(store, raw, context) do
          {:ok, event} -> {:cont, {:ok, acc ++ [event]}}
          {:error, _} = error -> {:halt, error}
        end
      end)

    results
  end

  # ============================================================================
  # Build
  # ============================================================================

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

  # ============================================================================
  # Enrich
  # ============================================================================

  defp enrich(event, context) do
    # Copy provider into metadata for backward compatibility with consumers
    # that read provider from metadata rather than the first-class field
    enriched_metadata = Map.put(event.metadata, :provider, context.provider)

    %{
      event
      | provider: context.provider,
        correlation_id: Map.get(context, :correlation_id),
        metadata: enriched_metadata
    }
  end

  # ============================================================================
  # Validate
  # ============================================================================

  defp validate(event) do
    with :ok <- EventValidator.validate_structural(event) do
      warnings = EventValidator.validate_shape(event)

      event =
        if warnings != [] do
          emit_warning_telemetry(event, warnings)
          updated_metadata = Map.put(event.metadata, :_validation_warnings, warnings)
          %{event | metadata: updated_metadata}
        else
          event
        end

      {:ok, event}
    end
  end

  # ============================================================================
  # Persist
  # ============================================================================

  defp persist(store, event) do
    SessionStore.append_event_with_sequence(store, event)
  end

  # ============================================================================
  # Telemetry
  # ============================================================================

  defp emit_persisted_telemetry(event, context) do
    :telemetry.execute(
      [:agent_session_manager, :persistence, :event_persisted],
      %{system_time: System.system_time(), sequence_number: event.sequence_number},
      %{
        session_id: event.session_id,
        run_id: event.run_id,
        type: event.type,
        provider: context.provider
      }
    )
  end

  defp emit_warning_telemetry(event, warnings) do
    :telemetry.execute(
      [:agent_session_manager, :persistence, :event_validation_warning],
      %{warning_count: length(warnings)},
      %{session_id: event.session_id, type: event.type, warnings: warnings}
    )
  end

  defp emit_rejected_telemetry(context, error) do
    :telemetry.execute(
      [:agent_session_manager, :persistence, :event_rejected],
      %{system_time: System.system_time()},
      %{session_id: context.session_id, reason: error.message}
    )
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp ensure_map(nil), do: %{}
  defp ensure_map(m) when is_map(m), do: m
  defp ensure_map(_), do: %{}
end
