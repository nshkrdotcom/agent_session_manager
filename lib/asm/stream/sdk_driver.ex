defmodule ASM.Stream.SDKDriver do
  @moduledoc """
  SDK-oriented stream driver.

  This driver bypasses transport attach/demand semantics and allows callers to
  provide a function that yields normalized events.
  """

  alias ASM.{Error, Event, Message, Run}
  alias ASM.Stream.Driver

  @behaviour Driver

  @type stream_item :: Event.t() | {Event.kind(), term()}
  @type stream_items ::
          Enumerable.t()
          | {:ok, Enumerable.t()}
          | {:error, Error.t() | term()}
  @type stream_fun :: (Driver.context() -> stream_items())

  @impl Driver
  @spec kind() :: Driver.kind()
  def kind, do: :sdk

  @impl Driver
  @spec start(Driver.context()) :: {:ok, pid()} | {:error, Error.t() | term()}
  def start(%{} = context) do
    with {:ok, fun} <- fetch_stream_fun(context) do
      {:ok, spawn(fn -> run(context, fun) end)}
    end
  rescue
    error ->
      {:error, Error.new(:runtime, :runtime, Exception.message(error), cause: error)}
  end

  @impl Driver
  @spec stop(pid(), Driver.context()) :: :ok
  def stop(pid, _context) when is_pid(pid) do
    if node(pid) == node() and Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    :ok
  end

  defp fetch_stream_fun(%{driver_opts: driver_opts}) when is_list(driver_opts) do
    case Keyword.get(driver_opts, :stream_fun) do
      fun when is_function(fun, 1) ->
        {:ok, fun}

      other ->
        {:error,
         Error.new(
           :config_invalid,
           :config,
           "sdk driver requires driver_opts[:stream_fun] (arity 1), got: #{inspect(other)}"
         )}
    end
  end

  defp fetch_stream_fun(_context) do
    {:error,
     Error.new(:config_invalid, :config, "sdk driver requires keyword driver_opts in context")}
  end

  defp run(context, stream_fun) do
    case fetch_stream_items(stream_fun, context) do
      {:ok, items} ->
        terminal? = emit_stream_items(context, items)
        maybe_emit_default_result(context, terminal?)

      {:error, %Error{} = error} ->
        emit_error(context, error)
    end
  end

  defp fetch_stream_items(stream_fun, context) do
    case stream_fun.(context) do
      {:ok, items} ->
        {:ok, items}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error, runtime_error("sdk stream failed: #{inspect(reason)}", reason)}

      items ->
        {:ok, items}
    end
  rescue
    error ->
      {:error, runtime_error("sdk stream failed: #{Exception.message(error)}", error)}
  catch
    kind, reason ->
      {:error, runtime_error("sdk stream failed: #{inspect({kind, reason})}", {kind, reason})}
  end

  defp emit_stream_items(context, items) do
    Enum.reduce_while(items, false, fn item, terminal? ->
      case normalize_event(item, context) do
        {:ok, %Event{} = event} ->
          Run.Server.ingest_event(context.run_pid, event)
          {:cont, terminal? or terminal_event?(event)}

        {:error, %Error{} = error} ->
          emit_error(context, error)
          {:halt, true}
      end
    end)
  rescue
    error ->
      emit_error(context, runtime_error("sdk stream failed: #{Exception.message(error)}", error))
      true
  catch
    kind, reason ->
      emit_error(
        context,
        runtime_error("sdk stream failed: #{inspect({kind, reason})}", {kind, reason})
      )

      true
  end

  defp maybe_emit_default_result(context, false) do
    Run.Server.ingest_event(
      context.run_pid,
      envelope(context, :result, %Message.Result{stop_reason: :end_turn})
    )
  end

  defp maybe_emit_default_result(_context, true), do: :ok

  defp normalize_event(%Event{} = event, context) do
    {:ok,
     %Event{
       id: event.id || Event.generate_id(),
       kind: event.kind,
       run_id: context.run_id,
       session_id: context.session_id,
       provider: context.provider,
       payload: event.payload,
       timestamp: event.timestamp || DateTime.utc_now(),
       sequence: event.sequence,
       correlation_id: event.correlation_id,
       causation_id: event.causation_id
     }}
  end

  defp normalize_event({kind, payload}, context) when is_atom(kind) do
    {:ok, envelope(context, kind, payload)}
  end

  defp normalize_event(other, _context) do
    {:error,
     Error.new(
       :runtime,
       :runtime,
       "sdk stream emitted unsupported item: #{inspect(other)}"
     )}
  end

  defp emit_error(context, %Error{} = error) do
    Run.Server.ingest_event(
      context.run_pid,
      envelope(
        context,
        :error,
        %Message.Error{
          severity: :error,
          message: error.message,
          kind: error.kind
        }
      )
    )
  end

  defp envelope(context, kind, payload) do
    %Event{
      id: Event.generate_id(),
      kind: kind,
      run_id: context.run_id,
      session_id: context.session_id,
      provider: context.provider,
      payload: payload,
      timestamp: DateTime.utc_now()
    }
  end

  defp terminal_event?(%Event{kind: kind}), do: kind in [:result, :error]

  defp runtime_error(message, cause) do
    Error.new(:runtime, :runtime, message, cause: cause)
  end
end
