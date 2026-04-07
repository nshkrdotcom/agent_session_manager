# credo:disable-for-this-file Credo.Check.Readability.PreferImplicitTry
defmodule ASM.Extensions.Rendering do
  @moduledoc """
  Public rendering extension API.

  This domain consumes `%ASM.Event{}` streams and dispatches renderer output
  to one or more sinks, keeping output concerns outside the run loop.
  """

  use Boundary,
    deps: [ASM],
    exports: [
      Renderer,
      Sink,
      Renderers.Compact,
      Renderers.Verbose,
      Sinks.TTY,
      Sinks.File,
      Sinks.JSONL,
      Sinks.Callback
    ]

  alias ASM.Error
  alias ASM.Extensions.Rendering.Renderers
  alias ASM.Extensions.Rendering.Sinks

  @type renderer_spec :: {module(), keyword()}
  @type sink_spec :: {module(), keyword()}

  @spec compact_renderer(keyword()) :: renderer_spec()
  def compact_renderer(opts \\ []) when is_list(opts), do: {Renderers.Compact, opts}

  @spec verbose_renderer(keyword()) :: renderer_spec()
  def verbose_renderer(opts \\ []) when is_list(opts), do: {Renderers.Verbose, opts}

  @spec tty_sink(keyword()) :: sink_spec()
  def tty_sink(opts \\ []) when is_list(opts), do: {Sinks.TTY, opts}

  @spec file_sink(keyword()) :: sink_spec()
  def file_sink(opts) when is_list(opts), do: {Sinks.File, opts}

  @spec jsonl_sink(keyword()) :: sink_spec()
  def jsonl_sink(opts) when is_list(opts), do: {Sinks.JSONL, opts}

  @spec callback_sink(keyword()) :: sink_spec()
  def callback_sink(opts \\ []) when is_list(opts), do: {Sinks.Callback, opts}

  @spec stream(Enumerable.t(), keyword()) :: :ok | {:error, Error.t()}
  def stream(event_stream, opts \\ []) when is_list(opts) do
    with {:ok, {renderer_mod, renderer_opts}} <-
           normalize_renderer_spec(Keyword.get(opts, :renderer)),
         {:ok, sink_specs} <- normalize_sink_specs(Keyword.get(opts, :sinks, [])),
         {:ok, renderer_state} <- init_renderer(renderer_mod, renderer_opts),
         {:ok, sink_states} <- init_sinks(sink_specs) do
      run_stream(event_stream, renderer_mod, renderer_state, sink_states)
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp run_stream(event_stream, renderer_mod, renderer_state, sink_states) do
    case process_events(event_stream, renderer_mod, renderer_state, sink_states) do
      {:ok, renderer_state, sink_states} ->
        finish_stream(renderer_mod, renderer_state, sink_states)

      {:error, %Error{} = error, _renderer_state, sink_states} ->
        finalize_sinks(sink_states, error)
    end
  end

  defp process_events(event_stream, renderer_mod, renderer_state, sink_states) do
    Enum.reduce_while(event_stream, {:ok, renderer_state, sink_states}, fn event,
                                                                           {:ok, acc_renderer,
                                                                            acc_sinks} ->
      case render_and_dispatch_event(renderer_mod, event, acc_renderer, acc_sinks) do
        {:ok, next_renderer, next_sinks} ->
          {:cont, {:ok, next_renderer, next_sinks}}

        {:error, %Error{} = error, next_renderer, next_sinks} ->
          {:halt, {:error, error, next_renderer, next_sinks}}
      end
    end)
  rescue
    error ->
      {:error, runtime_error("rendering stream crashed", error), renderer_state, sink_states}
  catch
    kind, reason ->
      {:error, runtime_error("rendering stream crashed", %{kind: kind, reason: reason}),
       renderer_state, sink_states}
  end

  defp render_and_dispatch_event(renderer_mod, event, renderer_state, sink_states) do
    with {:ok, iodata, next_renderer_state} <-
           call_renderer_render_event(renderer_mod, event, renderer_state),
         {:ok, next_sink_states} <- write_event_to_sinks(sink_states, event, iodata) do
      {:ok, next_renderer_state, next_sink_states}
    else
      {:error, %Error{} = error} ->
        {:error, error, renderer_state, sink_states}

      {:error, %Error{} = error, next_sink_states} ->
        {:error, error, renderer_state, next_sink_states}
    end
  end

  defp finish_stream(renderer_mod, renderer_state, sink_states) do
    with {:ok, finish_iodata, _state} <- call_renderer_finish(renderer_mod, renderer_state),
         {:ok, sink_states} <- write_finish_to_sinks(sink_states, finish_iodata) do
      finalize_sinks(sink_states, nil)
    else
      {:error, %Error{} = error} ->
        finalize_sinks(sink_states, error)

      {:error, %Error{} = error, next_sink_states} ->
        finalize_sinks(next_sink_states, error)
    end
  end

  defp init_renderer(renderer_mod, renderer_opts) do
    try do
      case renderer_mod.init(renderer_opts) do
        {:ok, state} ->
          {:ok, state}

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, reason} ->
          {:error, runtime_error("renderer init failed", reason)}

        other ->
          {:error, invalid_response_error("renderer init", renderer_mod, other)}
      end
    rescue
      error ->
        {:error, runtime_error("renderer init failed", error)}
    catch
      kind, reason ->
        {:error, runtime_error("renderer init failed", %{kind: kind, reason: reason})}
    end
  end

  defp init_sinks(sink_specs), do: init_sinks(sink_specs, [])

  defp init_sinks([], acc), do: {:ok, Enum.reverse(acc)}

  defp init_sinks([{sink_mod, sink_opts} | rest], acc) do
    try do
      case sink_mod.init(sink_opts) do
        {:ok, state} ->
          init_sinks(rest, [{sink_mod, state} | acc])

        {:error, %Error{} = error} ->
          _ = close_sinks_best_effort(acc)
          {:error, error}

        {:error, reason} ->
          _ = close_sinks_best_effort(acc)
          {:error, runtime_error("sink init failed", reason)}

        other ->
          _ = close_sinks_best_effort(acc)
          {:error, invalid_response_error("sink init", sink_mod, other)}
      end
    rescue
      error ->
        _ = close_sinks_best_effort(acc)
        {:error, runtime_error("sink init failed", error)}
    catch
      kind, reason ->
        _ = close_sinks_best_effort(acc)
        {:error, runtime_error("sink init failed", %{kind: kind, reason: reason})}
    end
  end

  defp write_event_to_sinks(sink_states, event, iodata),
    do: write_event_to_sinks(sink_states, event, iodata, [])

  defp write_event_to_sinks([], _event, _iodata, acc), do: {:ok, Enum.reverse(acc)}

  defp write_event_to_sinks([{sink_mod, sink_state} | rest], event, iodata, acc) do
    case call_sink_write_event(sink_mod, event, iodata, sink_state) do
      {:ok, next_sink_state} ->
        write_event_to_sinks(rest, event, iodata, [{sink_mod, next_sink_state} | acc])

      {:error, %Error{} = error, next_sink_state} ->
        {:error, error, Enum.reverse([{sink_mod, next_sink_state} | acc]) ++ rest}
    end
  end

  defp write_finish_to_sinks(sink_states, finish_iodata),
    do: write_finish_to_sinks(sink_states, finish_iodata, [])

  defp write_finish_to_sinks([], _finish_iodata, acc), do: {:ok, Enum.reverse(acc)}

  defp write_finish_to_sinks([{sink_mod, sink_state} | rest], finish_iodata, acc) do
    case call_sink_write(sink_mod, finish_iodata, sink_state) do
      {:ok, next_sink_state} ->
        write_finish_to_sinks(rest, finish_iodata, [{sink_mod, next_sink_state} | acc])

      {:error, %Error{} = error, next_sink_state} ->
        {:error, error, Enum.reverse([{sink_mod, next_sink_state} | acc]) ++ rest}
    end
  end

  defp finalize_sinks(sink_states, primary_error) do
    {sink_states, flush_error} = flush_sinks_best_effort(sink_states)
    close_error = close_sinks_best_effort(sink_states)
    error = first_error(primary_error, flush_error, close_error)

    case error do
      nil -> :ok
      %Error{} = value -> {:error, value}
    end
  end

  defp flush_sinks_best_effort(sink_states) do
    Enum.reduce(sink_states, {[], nil}, fn {sink_mod, sink_state}, {acc, first_error} ->
      case call_sink_flush(sink_mod, sink_state) do
        {:ok, next_sink_state} ->
          {[{sink_mod, next_sink_state} | acc], first_error}

        {:error, %Error{} = error, next_sink_state} ->
          {[{sink_mod, next_sink_state} | acc], first_error || error}
      end
    end)
    |> then(fn {reversed_states, first_error} -> {Enum.reverse(reversed_states), first_error} end)
  end

  defp close_sinks_best_effort(sink_states) do
    sink_states
    |> Enum.reverse()
    |> Enum.reduce(nil, fn {sink_mod, sink_state}, first_error ->
      case call_sink_close(sink_mod, sink_state) do
        :ok -> first_error
        {:error, %Error{} = error} -> first_error || error
      end
    end)
  end

  defp call_renderer_render_event(renderer_mod, event, renderer_state) do
    try do
      case renderer_mod.render_event(event, renderer_state) do
        {:ok, iodata, next_state} ->
          {:ok, iodata, next_state}

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, reason} ->
          {:error, runtime_error("renderer render_event failed", reason)}

        other ->
          {:error, invalid_response_error("renderer render_event", renderer_mod, other)}
      end
    rescue
      error -> {:error, runtime_error("renderer render_event failed", error)}
    catch
      kind, reason ->
        {:error, runtime_error("renderer render_event failed", %{kind: kind, reason: reason})}
    end
  end

  defp call_renderer_finish(renderer_mod, renderer_state) do
    try do
      case renderer_mod.finish(renderer_state) do
        {:ok, iodata, next_state} ->
          {:ok, iodata, next_state}

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, reason} ->
          {:error, runtime_error("renderer finish failed", reason)}

        other ->
          {:error, invalid_response_error("renderer finish", renderer_mod, other)}
      end
    rescue
      error -> {:error, runtime_error("renderer finish failed", error)}
    catch
      kind, reason ->
        {:error, runtime_error("renderer finish failed", %{kind: kind, reason: reason})}
    end
  end

  defp call_sink_write_event(sink_mod, event, iodata, sink_state) do
    try do
      case sink_mod.write_event(event, iodata, sink_state) do
        {:ok, next_state} ->
          {:ok, next_state}

        {:error, %Error{} = error, next_state} ->
          {:error, error, next_state}

        {:error, %Error{} = error} ->
          {:error, error, sink_state}

        {:error, reason, next_state} ->
          {:error, runtime_error("sink write_event failed", reason), next_state}

        {:error, reason} ->
          {:error, runtime_error("sink write_event failed", reason), sink_state}

        other ->
          {:error, invalid_response_error("sink write_event", sink_mod, other), sink_state}
      end
    rescue
      error ->
        {:error, runtime_error("sink write_event failed", error), sink_state}
    catch
      kind, reason ->
        {:error, runtime_error("sink write_event failed", %{kind: kind, reason: reason}),
         sink_state}
    end
  end

  defp call_sink_write(sink_mod, iodata, sink_state) do
    try do
      case sink_mod.write(iodata, sink_state) do
        {:ok, next_state} ->
          {:ok, next_state}

        {:error, %Error{} = error, next_state} ->
          {:error, error, next_state}

        {:error, %Error{} = error} ->
          {:error, error, sink_state}

        {:error, reason, next_state} ->
          {:error, runtime_error("sink write failed", reason), next_state}

        {:error, reason} ->
          {:error, runtime_error("sink write failed", reason), sink_state}

        other ->
          {:error, invalid_response_error("sink write", sink_mod, other), sink_state}
      end
    rescue
      error ->
        {:error, runtime_error("sink write failed", error), sink_state}
    catch
      kind, reason ->
        {:error, runtime_error("sink write failed", %{kind: kind, reason: reason}), sink_state}
    end
  end

  defp call_sink_flush(sink_mod, sink_state) do
    try do
      case sink_mod.flush(sink_state) do
        {:ok, next_state} ->
          {:ok, next_state}

        {:error, %Error{} = error, next_state} ->
          {:error, error, next_state}

        {:error, %Error{} = error} ->
          {:error, error, sink_state}

        {:error, reason, next_state} ->
          {:error, runtime_error("sink flush failed", reason), next_state}

        {:error, reason} ->
          {:error, runtime_error("sink flush failed", reason), sink_state}

        other ->
          {:error, invalid_response_error("sink flush", sink_mod, other), sink_state}
      end
    rescue
      error ->
        {:error, runtime_error("sink flush failed", error), sink_state}
    catch
      kind, reason ->
        {:error, runtime_error("sink flush failed", %{kind: kind, reason: reason}), sink_state}
    end
  end

  defp call_sink_close(sink_mod, sink_state) do
    try do
      case sink_mod.close(sink_state) do
        :ok ->
          :ok

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, reason} ->
          {:error, runtime_error("sink close failed", reason)}

        other ->
          {:error, invalid_response_error("sink close", sink_mod, other)}
      end
    rescue
      error ->
        {:error, runtime_error("sink close failed", error)}
    catch
      kind, reason ->
        {:error, runtime_error("sink close failed", %{kind: kind, reason: reason})}
    end
  end

  defp normalize_renderer_spec(nil), do: {:ok, compact_renderer()}

  defp normalize_renderer_spec({renderer_mod, renderer_opts})
       when is_atom(renderer_mod) and is_list(renderer_opts) do
    with :ok <- ensure_loaded(renderer_mod),
         :ok <- ensure_export(renderer_mod, :init, 1, :renderer),
         :ok <- ensure_export(renderer_mod, :render_event, 2, :renderer),
         :ok <- ensure_export(renderer_mod, :finish, 1, :renderer) do
      {:ok, {renderer_mod, renderer_opts}}
    end
  end

  defp normalize_renderer_spec(other) do
    {:error, config_error("renderer must be {module, keyword}, got: #{inspect(other)}")}
  end

  defp normalize_sink_specs(sink_specs) when is_list(sink_specs) do
    sink_specs
    |> Enum.reduce_while({:ok, []}, fn
      {sink_mod, sink_opts}, {:ok, acc} when is_atom(sink_mod) and is_list(sink_opts) ->
        with :ok <- ensure_loaded(sink_mod),
             :ok <- ensure_export(sink_mod, :init, 1, :sink),
             :ok <- ensure_export(sink_mod, :write, 2, :sink),
             :ok <- ensure_export(sink_mod, :write_event, 3, :sink),
             :ok <- ensure_export(sink_mod, :flush, 1, :sink),
             :ok <- ensure_export(sink_mod, :close, 1, :sink) do
          {:cont, {:ok, [{sink_mod, sink_opts} | acc]}}
        else
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      invalid, _acc ->
        {:halt,
         {:error, config_error("sink must be {module, keyword}, got: #{inspect(invalid)}")}}
    end)
    |> case do
      {:ok, reversed_specs} -> {:ok, Enum.reverse(reversed_specs)}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp normalize_sink_specs(other) do
    {:error, config_error("sinks must be a list, got: #{inspect(other)}")}
  end

  defp ensure_loaded(module) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      {:error, config_error("module is not available: #{inspect(module)}")}
    end
  end

  defp ensure_export(module, function, arity, kind) do
    if function_exported?(module, function, arity) do
      :ok
    else
      {:error, config_error("#{kind} module #{inspect(module)} must export #{function}/#{arity}")}
    end
  end

  defp first_error(nil, nil, nil), do: nil
  defp first_error(%Error{} = error, _other, _third), do: error
  defp first_error(nil, %Error{} = error, _third), do: error
  defp first_error(nil, nil, %Error{} = error), do: error

  defp invalid_response_error(operation, module, response) do
    config_error(
      "#{operation} returned invalid response from #{inspect(module)}: #{inspect(response)}"
    )
  end

  defp config_error(message) do
    Error.new(:config_invalid, :config, message)
  end

  defp runtime_error(message, cause) do
    Error.new(:unknown, :runtime, message, cause: cause)
  end
end
