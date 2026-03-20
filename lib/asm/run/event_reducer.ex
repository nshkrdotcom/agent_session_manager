defmodule ASM.Run.EventReducer do
  @moduledoc """
  Deterministic reducer from run-scoped events to result projections.
  """

  alias ASM.{Error, Event, Metadata, Result, Run}

  @conversation_kinds [
    :assistant_message,
    :assistant_delta,
    :user_message,
    :tool_use,
    :tool_result,
    :thinking,
    :result,
    :stderr,
    :raw
  ]

  @spec apply_event!(Run.State.t(), Event.t()) :: Run.State.t()
  def apply_event!(%Run.State{} = state, %Event{} = event) do
    next_sequence = max(state.sequence + 1, event.sequence || state.sequence + 1)
    event = %{event | sequence: next_sequence}
    state = %{state | metadata: Metadata.merge_run_metadata(state.metadata, event.metadata)}

    state
    |> append_event(event)
    |> apply_semantics(event)
  end

  @spec final?(Run.State.t()) :: boolean()
  def final?(%Run.State{status: status}) do
    status in [:completed, :failed, :interrupted]
  end

  @spec to_result(Run.State.t()) :: Result.t()
  def to_result(%Run.State{} = state) do
    state = Run.State.materialize(state)

    duration_ms =
      case state.finished_at do
        %DateTime{} = finished_at ->
          finished_at
          |> DateTime.diff(state.started_at, :millisecond)
          |> max(0)

        nil ->
          nil
      end

    stop_reason =
      case state.result do
        %Result{stop_reason: reason} -> reason
        _ -> nil
      end

    %Result{
      run_id: state.run_id,
      session_id: state.session_id,
      text: state.text_acc,
      messages: state.messages_acc,
      cost: state.cost,
      error: state.error,
      duration_ms: duration_ms,
      stop_reason: stop_reason,
      session_id_from_cli:
        state.metadata[:provider_session_id] || state.metadata["provider_session_id"],
      metadata: state.metadata
    }
  end

  defp append_event(state, event) do
    %{state | sequence: event.sequence, events_rev: [event | state.events_rev]}
  end

  defp append_message(state, nil), do: state

  defp append_message(state, payload) do
    %{state | messages_rev: [payload | state.messages_rev]}
  end

  defp append_text(state, ""), do: state
  defp append_text(state, nil), do: state

  defp append_text(state, text) when is_binary(text) do
    %{state | text_chunks_rev: [text | state.text_chunks_rev]}
  end

  defp apply_semantics(state, %Event{kind: :run_started, provider_session_id: provider_session_id}) do
    metadata = put_if_present(state.metadata, :provider_session_id, provider_session_id)
    %{state | status: :running, metadata: metadata}
  end

  defp apply_semantics(state, %Event{} = event)
       when event.kind in [:assistant_delta, :assistant_message] do
    legacy = Event.legacy_payload(event)

    state
    |> append_message(legacy)
    |> append_text(Event.assistant_text(event))
  end

  defp apply_semantics(state, %Event{kind: :result, timestamp: finished_at} = event) do
    legacy = Event.legacy_payload(event)

    next_state =
      state
      |> append_message(legacy)
      |> Map.put(:status, :completed)
      |> Map.put(:finished_at, finished_at)

    materialized = Run.State.materialize(next_state)

    result =
      %Result{
        run_id: materialized.run_id,
        session_id: materialized.session_id,
        text: materialized.text_acc,
        messages: materialized.messages_acc,
        cost: materialized.cost,
        error: materialized.error,
        duration_ms: legacy.duration_ms,
        stop_reason: legacy.stop_reason,
        metadata: materialized.metadata
      }

    %{next_state | result: result}
  end

  defp apply_semantics(state, %Event{kind: :error, timestamp: finished_at} = event) do
    legacy = Event.legacy_payload(event)

    state
    |> append_message(legacy)
    |> Map.put(:status, :failed)
    |> Map.put(:finished_at, finished_at)
    |> Map.put(:error, error_from_message(legacy))
  end

  defp apply_semantics(state, %Event{kind: :run_completed, timestamp: finished_at}) do
    %{state | status: :completed, finished_at: finished_at}
  end

  defp apply_semantics(state, %Event{kind: :approval_requested} = event) do
    payload = Event.legacy_payload(event)
    %{state | pending_approvals: Map.put(state.pending_approvals, payload.approval_id, payload)}
  end

  defp apply_semantics(state, %Event{kind: :approval_resolved} = event) do
    payload = Event.legacy_payload(event)
    %{state | pending_approvals: Map.delete(state.pending_approvals, payload.approval_id)}
  end

  defp apply_semantics(state, %Event{kind: :cost_update} = event) do
    payload = Event.legacy_payload(event)
    totals = add_cost(state.cost, payload)
    %{state | cost: totals, metadata: Map.put(state.metadata, :cost, totals)}
  end

  defp apply_semantics(state, %Event{kind: kind} = event) when kind in @conversation_kinds do
    append_message(state, Event.legacy_payload(event))
  end

  defp apply_semantics(state, _event), do: state

  defp add_cost(current, payload) do
    %{
      input_tokens: default_zero(current[:input_tokens]) + payload.input_tokens,
      output_tokens: default_zero(current[:output_tokens]) + payload.output_tokens,
      cost_usd: default_zero(current[:cost_usd]) + payload.cost_usd
    }
  end

  defp default_zero(nil), do: 0
  defp default_zero(value), do: value

  defp error_from_message(%ASM.Message.Error{} = payload) do
    Error.new(payload.kind, :runtime, payload.message)
  end

  defp error_from_message(_payload) do
    Error.new(:unknown, :runtime, "Unknown runtime error")
  end

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
