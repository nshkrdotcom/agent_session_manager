defmodule ASM.Extensions.PubSub.PipelinePlug do
  @moduledoc """
  Non-blocking pipeline plug that forwards events to an async PubSub broadcaster.

  Options:
  - `:broadcaster` (required): broadcaster pid from `ASM.Extensions.PubSub.start_broadcaster/1`
  - `:publish_opts` (optional): topic/payload overrides for this plug call
  - `:on_failure` (optional): `:drop` (default) or `:halt`
  """

  @behaviour ASM.Pipeline.Plug

  alias ASM.{Error, Event, Telemetry}
  alias ASM.Extensions.PubSub.Broadcaster

  @type on_failure :: :drop | :halt

  @impl true
  @spec call(Event.t(), map(), keyword()) ::
          {:ok, Event.t(), map()} | {:error, Error.t(), map()}
  def call(%Event{} = event, ctx, opts) when is_map(ctx) and is_list(opts) do
    on_failure = Keyword.get(opts, :on_failure, :drop)
    publish_opts = Keyword.get(opts, :publish_opts, [])

    case Keyword.fetch(opts, :broadcaster) do
      {:ok, broadcaster} when is_pid(broadcaster) ->
        if Process.alive?(broadcaster) do
          :ok = Broadcaster.enqueue(broadcaster, event, publish_opts)
          {:ok, event, ctx}
        else
          handle_unavailable_broadcaster(event, ctx, on_failure)
        end

      _missing_or_invalid ->
        handle_unavailable_broadcaster(event, ctx, on_failure)
    end
  end

  defp handle_unavailable_broadcaster(%Event{} = event, ctx, :halt) do
    error = Error.new(:unknown, :runtime, "pubsub pipeline broadcaster is unavailable")
    emit_drop_telemetry(event, error)
    {:error, error, ctx}
  end

  defp handle_unavailable_broadcaster(%Event{} = event, ctx, _drop) do
    error = Error.new(:unknown, :runtime, "pubsub pipeline broadcaster is unavailable")
    emit_drop_telemetry(event, error)
    {:ok, event, ctx}
  end

  defp emit_drop_telemetry(%Event{} = event, %Error{} = error) do
    Telemetry.execute([:asm, :ext, :pub_sub, :pipeline, :drop], %{}, %{
      session_id: event.session_id,
      run_id: event.run_id,
      event_id: event.id,
      event_kind: event.kind,
      error_kind: error.kind,
      error_domain: error.domain
    })
  end
end
