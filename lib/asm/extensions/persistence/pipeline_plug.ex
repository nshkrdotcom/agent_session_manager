defmodule ASM.Extensions.Persistence.PipelinePlug do
  @moduledoc """
  Non-blocking pipeline plug that forwards events to an async persistence writer.

  Options:
  - `:writer` (required): writer pid started via `ASM.Extensions.Persistence.start_writer/1`
  - `:on_failure` (optional): `:drop` (default) or `:halt`
  """

  @behaviour ASM.Pipeline.Plug

  alias ASM.{Error, Event, Telemetry}
  alias ASM.Extensions.Persistence.Writer

  @type on_failure :: :drop | :halt

  @impl true
  @spec call(Event.t(), map(), keyword()) ::
          {:ok, Event.t(), map()} | {:error, Error.t(), map()}
  def call(%Event{} = event, ctx, opts) when is_map(ctx) and is_list(opts) do
    on_failure = Keyword.get(opts, :on_failure, :drop)

    case Keyword.fetch(opts, :writer) do
      {:ok, writer} when is_pid(writer) ->
        if Process.alive?(writer) do
          :ok = Writer.enqueue(writer, event)
          {:ok, event, ctx}
        else
          handle_unavailable_writer(event, ctx, on_failure)
        end

      _missing_or_down ->
        handle_unavailable_writer(event, ctx, on_failure)
    end
  end

  defp handle_unavailable_writer(%Event{} = event, ctx, :halt) do
    error =
      Error.new(
        :unknown,
        :runtime,
        "persistence pipeline writer is unavailable"
      )

    emit_drop_telemetry(event, error)
    {:error, error, ctx}
  end

  defp handle_unavailable_writer(%Event{} = event, ctx, _drop) do
    error = Error.new(:unknown, :runtime, "persistence pipeline writer is unavailable")
    emit_drop_telemetry(event, error)
    {:ok, event, ctx}
  end

  defp emit_drop_telemetry(%Event{} = event, %Error{} = error) do
    Telemetry.execute([:asm, :ext, :persistence, :pipeline, :drop], %{}, %{
      session_id: event.session_id,
      run_id: event.run_id,
      event_id: event.id,
      event_kind: event.kind,
      error_kind: error.kind,
      error_domain: error.domain
    })
  end
end
