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

  alias AgentSessionManager.Core.{Error, Event}
  alias AgentSessionManager.Persistence.EventBuilder
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
    with {:ok, built_events} <- build_batch(raw_events, context),
         {:ok, persisted_events} <- SessionStore.append_events(store, built_events) do
      Enum.each(persisted_events, &emit_persisted_telemetry(&1, context))
      {:ok, persisted_events}
    else
      {:error, %Error{} = error} ->
        emit_rejected_telemetry(context, error)
        {:error, error}
    end
  end

  # ============================================================================
  # Persist
  # ============================================================================

  defp persist(store, event) do
    SessionStore.append_event_with_sequence(store, event)
  end

  defp build_event(raw_event_data, context) when is_map(raw_event_data) do
    with {:ok, event} <- EventBuilder.process(raw_event_data, context) do
      emit_validation_warning_if_present(event)
    end
  end

  defp build_event(_raw_event_data, _context) do
    {:error, Error.new(:validation_error, "raw event data must be a map")}
  end

  defp build_batch(raw_events, context) do
    Enum.reduce_while(raw_events, {:ok, []}, fn raw_event, {:ok, acc} ->
      case build_event(raw_event, context) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      {:error, _} = error -> error
    end
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

  defp emit_validation_warning_if_present(event) do
    case Map.get(event.metadata, :_validation_warnings, []) do
      warnings when is_list(warnings) and warnings != [] ->
        emit_warning_telemetry(event, warnings)
        {:ok, event}

      _ ->
        {:ok, event}
    end
  end
end
