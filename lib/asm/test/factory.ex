defmodule ASM.Test.Factory do
  @moduledoc """
  Builders for normalized runtime structs used in tests.
  """

  alias ASM.Event

  @spec event(ASM.Event.kind(), term(), keyword()) :: Event.t()
  def event(kind, payload, opts \\ []) when is_list(opts) do
    %Event{
      id: Keyword.get(opts, :id, Event.generate_id()),
      kind: kind,
      run_id: Keyword.get(opts, :run_id, "run-test"),
      session_id: Keyword.get(opts, :session_id, "session-test"),
      provider: Keyword.get(opts, :provider, :claude),
      payload: payload,
      sequence: Keyword.get(opts, :sequence),
      correlation_id: Keyword.get(opts, :correlation_id),
      causation_id: Keyword.get(opts, :causation_id),
      timestamp: Keyword.get(opts, :timestamp, DateTime.utc_now())
    }
  end
end
