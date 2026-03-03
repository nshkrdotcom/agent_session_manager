defmodule ASM.Run.EventReducer do
  @moduledoc """
  Deterministic reducer from event envelopes to run state projection.
  """

  alias ASM.{Content, Control, Event, Message, Result, Run}

  @conversation_kinds [
    :assistant_message,
    :assistant_delta,
    :user_message,
    :tool_use,
    :tool_result,
    :thinking,
    :result,
    :error,
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
      duration_ms: duration_ms,
      stop_reason: stop_reason,
      metadata: state.metadata
    }
  end

  defp append_event(state, event) do
    %{state | sequence: event.sequence, events: state.events ++ [event]}
  end

  defp apply_semantics(state, %Event{kind: :run_started}) do
    %{state | status: :running}
  end

  defp apply_semantics(state, %Event{
         kind: :assistant_message,
         payload: %Message.Assistant{} = msg
       }) do
    text = extract_text_blocks(msg.content)

    %{
      state
      | text_acc: state.text_acc <> text,
        messages_acc: state.messages_acc ++ [msg]
    }
  end

  defp apply_semantics(
         state,
         %Event{
           kind: :assistant_delta,
           payload: %Message.Partial{content_type: :text, delta: delta} = msg
         }
       ) do
    %{state | text_acc: state.text_acc <> delta, messages_acc: state.messages_acc ++ [msg]}
  end

  defp apply_semantics(
         state,
         %Event{kind: :result, payload: %Message.Result{} = payload, timestamp: finished_at}
       ) do
    %{
      state
      | status: :completed,
        finished_at: finished_at,
        messages_acc: state.messages_acc ++ [payload],
        result: %Result{
          run_id: state.run_id,
          session_id: state.session_id,
          text: state.text_acc,
          messages: state.messages_acc ++ [payload],
          duration_ms: payload.duration_ms,
          stop_reason: payload.stop_reason,
          metadata: payload.metadata
        }
    }
  end

  defp apply_semantics(
         state,
         %Event{kind: :error, payload: %Message.Error{} = payload, timestamp: finished_at}
       ) do
    %{
      state
      | status: :failed,
        finished_at: finished_at,
        messages_acc: state.messages_acc ++ [payload]
    }
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
    %{state | metadata: Map.put(state.metadata, :cost, payload)}
  end

  defp apply_semantics(state, %Event{kind: kind, payload: payload})
       when kind in @conversation_kinds do
    %{state | messages_acc: state.messages_acc ++ [payload]}
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
end
