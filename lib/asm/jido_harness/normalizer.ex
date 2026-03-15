defmodule ASM.JidoHarness.Normalizer do
  @moduledoc false

  alias ASM.{Error, Event, Result}

  alias Jido.Harness.{
    ExecutionEvent,
    ExecutionResult,
    SessionHandle
  }

  @spec canonical_provider(atom() | nil) :: atom() | nil
  def canonical_provider(:codex_exec), do: :codex
  def canonical_provider(provider) when is_atom(provider), do: provider
  def canonical_provider(_other), do: nil

  @spec to_execution_event(Event.t(), SessionHandle.t()) :: ExecutionEvent.t()
  def to_execution_event(%Event{} = event, %SessionHandle{} = session) do
    ExecutionEvent.new!(%{
      event_id: event.id,
      type: event.kind,
      session_id: session.session_id,
      run_id: event.run_id,
      runtime_id: session.runtime_id,
      provider: session.provider || canonical_provider(event.provider),
      sequence: event.sequence,
      timestamp: DateTime.to_iso8601(event.timestamp),
      status: event_status(event.kind),
      payload: normalize_payload(event.payload),
      raw: event,
      metadata:
        %{}
        |> maybe_put("correlation_id", event.correlation_id)
        |> maybe_put("causation_id", event.causation_id)
    })
  end

  @spec to_execution_result(Result.t(), SessionHandle.t()) :: ExecutionResult.t()
  def to_execution_result(%Result{} = result, %SessionHandle{} = session) do
    metadata =
      result.metadata
      |> normalize()
      |> default_map()
      |> maybe_put("provider_session_id", result.session_id_from_cli)

    ExecutionResult.new!(%{
      run_id: result.run_id,
      session_id: session.session_id,
      runtime_id: session.runtime_id,
      provider: session.provider,
      status: result_status(result),
      text: result.text,
      messages: normalize(result.messages || []),
      cost: result.cost |> normalize() |> default_map(),
      error: normalize_error(result.error),
      duration_ms: result.duration_ms,
      stop_reason: normalize_reason(result.stop_reason),
      metadata: metadata
    })
  end

  @spec normalize(term()) :: term()
  def normalize(nil), do: nil
  def normalize(value) when is_boolean(value), do: value
  def normalize(value) when is_integer(value), do: value
  def normalize(value) when is_float(value), do: value
  def normalize(value) when is_binary(value), do: value
  def normalize(value) when is_atom(value), do: Atom.to_string(value)
  def normalize(%DateTime{} = value), do: DateTime.to_iso8601(value)

  def normalize(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize()
  end

  def normalize(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), normalize(value)} end)
  end

  def normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  def normalize(other), do: other

  defp normalize_payload(nil), do: %{}

  defp normalize_payload(payload) do
    payload
    |> normalize()
    |> default_payload_map()
  end

  defp normalize_error(nil), do: nil

  defp normalize_error(%Error{} = error) do
    error
    |> Map.from_struct()
    |> normalize()
    |> default_map()
  end

  defp normalize_error(other) do
    other
    |> normalize()
    |> default_payload_map()
  end

  defp normalize_reason(nil), do: nil
  defp normalize_reason(reason) when is_binary(reason), do: reason
  defp normalize_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp normalize_reason(reason), do: inspect(reason)

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: inspect(key)

  defp result_status(%Result{error: nil}), do: :completed
  defp result_status(%Result{error: %Error{kind: :user_cancelled}}), do: :cancelled
  defp result_status(%Result{}), do: :failed

  defp event_status(:run_started), do: :running
  defp event_status(:result), do: :completed
  defp event_status(:run_completed), do: :completed
  defp event_status(:error), do: :failed
  defp event_status(_kind), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp default_payload_map(%{} = value), do: value
  defp default_payload_map(other), do: %{"value" => other}

  defp default_map(%{} = value), do: value
  defp default_map(_other), do: %{}
end
