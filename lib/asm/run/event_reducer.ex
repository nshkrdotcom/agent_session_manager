defmodule ASM.Run.EventReducer do
  @moduledoc """
  Deterministic reducer from event envelopes to run state projection.
  """

  alias ASM.{Content, Control, Error, Event, Message, Result, Run}

  @conversation_kinds [
    :assistant_message,
    :assistant_delta,
    :user_message,
    :tool_use,
    :tool_result,
    :thinking,
    :result,
    :system,
    :raw
  ]

  @spec apply_event!(Run.State.t(), Event.t()) :: Run.State.t()
  def apply_event!(%Run.State{} = state, %Event{} = event) do
    next_sequence = max(state.sequence + 1, event.sequence || state.sequence + 1)
    event = %{event | sequence: next_sequence}

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
        %DateTime{} = finished_at -> DateTime.diff(finished_at, state.started_at, :millisecond)
        nil -> nil
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
      metadata: state.metadata
    }
  end

  defp append_event(state, event) do
    %{state | sequence: event.sequence, events_rev: [event | state.events_rev]}
  end

  defp append_message(state, payload) do
    %{state | messages_rev: [payload | state.messages_rev]}
  end

  defp append_text(state, ""), do: state
  defp append_text(state, nil), do: state

  defp append_text(state, text) when is_binary(text) do
    %{state | text_chunks_rev: [text | state.text_chunks_rev]}
  end

  defp apply_semantics(state, %Event{kind: :run_started}) do
    %{state | status: :running}
  end

  defp apply_semantics(state, %Event{
         kind: :assistant_message,
         payload: %Message.Assistant{} = msg
       }) do
    msg.content
    |> extract_text_blocks()
    |> then(fn text ->
      state
      |> append_message(msg)
      |> append_text(text)
    end)
  end

  defp apply_semantics(
         state,
         %Event{
           kind: :assistant_delta,
           payload: %Message.Partial{content_type: :text, delta: delta} = msg
         }
       ) do
    state
    |> append_message(msg)
    |> append_text(delta)
  end

  defp apply_semantics(
         state,
         %Event{kind: :result, payload: %Message.Result{} = payload, timestamp: finished_at}
       ) do
    next_state =
      state
      |> append_message(payload)
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
        duration_ms: payload.duration_ms,
        stop_reason: payload.stop_reason,
        metadata: payload.metadata
      }

    %{next_state | result: result}
  end

  defp apply_semantics(
         state,
         %Event{kind: :error, payload: %Message.Error{} = payload, timestamp: finished_at}
       ) do
    state
    |> append_message(payload)
    |> Map.put(:status, :failed)
    |> Map.put(:finished_at, finished_at)
    |> Map.put(:error, error_from_message(payload))
  end

  defp apply_semantics(state, %Event{kind: :run_completed, timestamp: finished_at}) do
    %{state | status: :completed, finished_at: finished_at}
  end

  defp apply_semantics(
         state,
         %Event{kind: :approval_requested, payload: %ASM.Control.ApprovalRequest{} = payload}
       ) do
    %{state | pending_approvals: Map.put(state.pending_approvals, payload.approval_id, payload)}
  end

  defp apply_semantics(
         state,
         %Event{kind: :approval_resolved, payload: %ASM.Control.ApprovalResolution{} = payload}
       ) do
    %{state | pending_approvals: Map.delete(state.pending_approvals, payload.approval_id)}
  end

  defp apply_semantics(
         state,
         %Event{kind: :cost_update, payload: %Control.CostUpdate{} = payload}
       ) do
    totals = add_cost(state.cost, payload)
    %{state | cost: totals, metadata: Map.put(state.metadata, :cost, totals)}
  end

  defp apply_semantics(state, %Event{kind: kind, payload: payload})
       when kind in @conversation_kinds do
    append_message(state, payload)
  end

  defp apply_semantics(state, _event), do: state

  defp extract_text_blocks(content_blocks) do
    content_blocks
    |> Enum.flat_map(fn
      %Content.Text{text: text} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join()
  end

  defp add_cost(current, %Control.CostUpdate{} = payload) do
    %{
      input_tokens: default_zero(current[:input_tokens]) + payload.input_tokens,
      output_tokens: default_zero(current[:output_tokens]) + payload.output_tokens,
      cost_usd: default_zero(current[:cost_usd]) + payload.cost_usd
    }
  end

  defp default_zero(nil), do: 0
  defp default_zero(value), do: value

  defp error_from_message(%Message.Error{} = payload) do
    Error.new(payload.kind, :runtime, payload.message)
  end
end
