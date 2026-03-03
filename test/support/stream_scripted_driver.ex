defmodule ASM.TestSupport.StreamScriptedDriver do
  @moduledoc false

  alias ASM.{Event, Message, Run}

  @spec start(map()) :: {:ok, pid()}
  def start(%{} = context) do
    {:ok, spawn(fn -> emit(context) end)}
  end

  defp emit(context) do
    script = Keyword.get(context.driver_opts, :script, default_script())

    Enum.each(script, fn {kind, payload} ->
      event = %Event{
        id: Event.generate_id(),
        kind: kind,
        run_id: context.run_id,
        session_id: context.session_id,
        provider: context.provider,
        payload: payload,
        timestamp: DateTime.utc_now()
      }

      Run.Server.ingest_event(context.run_pid, event)
    end)
  end

  defp default_script do
    [
      {:assistant_delta, %Message.Partial{content_type: :text, delta: "hello "}},
      {:assistant_delta, %Message.Partial{content_type: :text, delta: "from scripted driver"}},
      {:result, %Message.Result{stop_reason: :end_turn}}
    ]
  end
end
