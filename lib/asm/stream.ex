defmodule ASM.Stream do
  @moduledoc """
  Stream helpers for run event consumption and final result projection.
  """

  alias ASM.{Content, Error, Event, Run, Session}

  @stream_keys [:driver, :driver_opts, :stream_timeout_ms, :queue_timeout_ms]
  @run_keys [
    :run_id,
    :run_module,
    :run_module_opts,
    :tools,
    :tool_executor,
    :pipeline,
    :pipeline_ctx,
    :approval_timeout_ms
  ]

  @type stream_state :: %{
          session: GenServer.server(),
          session_id: String.t(),
          provider: atom(),
          prompt: String.t(),
          provider_opts: keyword(),
          run_id: String.t(),
          run_pid: pid() | nil,
          driver: module(),
          driver_opts: keyword(),
          driver_pid: pid() | nil,
          driver_ref: reference() | nil,
          timeout_ms: pos_integer(),
          queue_timeout_ms: pos_integer() | :infinity,
          queue_started_at_ms: integer() | nil,
          started?: boolean(),
          done?: boolean()
        }

  @spec create(GenServer.server(), String.t(), keyword()) :: Enumerable.t()
  def create(session, prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    Elixir.Stream.resource(
      fn -> init_stream(session, prompt, opts) end,
      &next_event/1,
      &close_stream/1
    )
  end

  @spec final_result(Enumerable.t()) :: ASM.Result.t()
  def final_result(events) do
    case Enum.reduce(events, nil, &reduce_event/2) do
      nil ->
        raise ArgumentError, "stream produced no events"

      %Run.State{} = run_state ->
        Run.EventReducer.to_result(run_state)
    end
  end

  @spec text_deltas(Enumerable.t()) :: Enumerable.t()
  def text_deltas(events) do
    Elixir.Stream.flat_map(events, fn
      %Event{
        kind: :assistant_delta,
        payload: %ASM.Message.Partial{content_type: :text, delta: delta}
      }
      when is_binary(delta) ->
        [delta]

      _other ->
        []
    end)
  end

  @spec text_content(Enumerable.t()) :: Enumerable.t()
  def text_content(events) do
    Elixir.Stream.flat_map(events, fn
      %Event{
        kind: :assistant_delta,
        payload: %ASM.Message.Partial{content_type: :text, delta: delta}
      }
      when is_binary(delta) ->
        [delta]

      %Event{kind: :assistant_message, payload: %ASM.Message.Assistant{content: blocks}} ->
        extract_text_blocks(blocks)

      %ASM.Message.Partial{content_type: :text, delta: delta} when is_binary(delta) ->
        [delta]

      %ASM.Message.Assistant{content: blocks} ->
        extract_text_blocks(blocks)

      _other ->
        []
    end)
  end

  @spec final_text(Enumerable.t()) :: String.t()
  def final_text(events) do
    events
    |> text_content()
    |> Enum.join()
  end

  defp init_stream(session, prompt, opts) do
    session_state = Session.Server.get_state(session)

    {session_stream_opts, session_run_opts, session_provider_opts} =
      partition_opts(session_state.options)

    {call_stream_opts, call_run_opts, call_provider_opts} = partition_opts(opts)

    stream_opts = merge_opts(session_stream_opts, call_stream_opts)
    run_opts = merge_opts(session_run_opts, call_run_opts)
    provider_opts = merge_opts(session_provider_opts, call_provider_opts)

    run_opts =
      run_opts
      |> Keyword.update(:run_module_opts, [subscriber: self()], fn module_opts ->
        Keyword.put_new(module_opts, :subscriber, self())
      end)

    case Session.Server.submit_run(session, prompt, run_opts) do
      {:ok, run_id, run_pid_or_queued} ->
        run_pid = if(is_pid(run_pid_or_queued), do: run_pid_or_queued, else: nil)

        state = %{
          session: session,
          session_id: session_state.session_id,
          provider: session_state.provider.name,
          prompt: prompt,
          provider_opts: provider_opts,
          run_id: run_id,
          run_pid: run_pid,
          driver: Keyword.get(stream_opts, :driver, ASM.Stream.CLIDriver),
          driver_opts: Keyword.get(stream_opts, :driver_opts, []),
          driver_pid: nil,
          driver_ref: nil,
          timeout_ms: max(Keyword.get(stream_opts, :stream_timeout_ms, 60_000), 1),
          queue_timeout_ms:
            normalize_queue_timeout(Keyword.get(stream_opts, :queue_timeout_ms, :infinity)),
          queue_started_at_ms: if(is_pid(run_pid), do: nil, else: monotonic_ms()),
          started?: is_pid(run_pid),
          done?: false
        }

        maybe_start_driver(state)

      {:error, %Error{} = error} ->
        raise error
    end
  end

  defp next_event(%{done?: true} = state), do: {:halt, state}

  defp next_event(state) do
    timeout = receive_timeout(state)

    receive do
      {:asm_run_event, run_id, %Event{} = event} when run_id == state.run_id ->
        next_state =
          state
          |> maybe_mark_started(event)
          |> maybe_start_driver_on_bootstrap(event)

        {[event], next_state}

      {:asm_run_done, run_id} when run_id == state.run_id ->
        await_session_cleanup(state.session, state.run_id, state.timeout_ms)
        {:halt, %{state | done?: true}}

      {:DOWN, ref, :process, pid, reason}
      when ref == state.driver_ref and pid == state.driver_pid ->
        state = %{state | driver_pid: nil, driver_ref: nil}

        if reason not in [:normal, :shutdown] and is_pid(state.run_pid) and
             state.driver != ASM.Stream.CLIDriver do
          emit_driver_error(
            state.run_pid,
            state,
            runtime_error("driver crashed: #{inspect(reason)}")
          )
        end

        next_event(state)

      _other ->
        next_event(state)
    after
      timeout ->
        raise timeout_error(state)
    end
  end

  defp close_stream(state) do
    if state.driver_ref, do: Process.demonitor(state.driver_ref, [:flush])

    if is_pid(state.driver_pid) and Process.alive?(state.driver_pid) do
      Process.exit(state.driver_pid, :kill)
    end

    unless state.done? do
      _ = Session.Server.cancel_run(state.session, state.run_id)
    end

    :ok
  end

  defp maybe_start_driver(%{run_pid: run_pid} = state) when is_pid(run_pid) do
    driver_ctx = %{
      run_id: state.run_id,
      run_pid: run_pid,
      session_id: state.session_id,
      provider: state.provider,
      prompt: state.prompt,
      provider_opts: state.provider_opts,
      driver_opts: state.driver_opts
    }

    case state.driver.start(driver_ctx) do
      {:ok, pid} when is_pid(pid) ->
        %{state | driver_pid: pid, driver_ref: Process.monitor(pid)}

      {:error, %Error{} = error} ->
        emit_driver_error(run_pid, state, error)
        state

      {:error, reason} ->
        emit_driver_error(run_pid, state, runtime_error("driver failed: #{inspect(reason)}"))
        state
    end
  end

  defp maybe_start_driver(state), do: state

  defp maybe_start_driver_on_bootstrap(%{run_pid: nil} = state, %Event{kind: :run_started}) do
    case lookup_run_pid(state.session, state.run_id) do
      {:ok, run_pid} -> maybe_start_driver(%{state | run_pid: run_pid, started?: true})
      :error -> state
    end
  end

  defp maybe_start_driver_on_bootstrap(state, _event), do: state

  defp maybe_mark_started(state, %Event{kind: :run_started}) do
    %{state | started?: true, queue_started_at_ms: nil}
  end

  defp maybe_mark_started(state, _event), do: state

  defp lookup_run_pid(session, run_id, attempts \\ 40)

  defp lookup_run_pid(_session, _run_id, 0), do: :error

  defp lookup_run_pid(session, run_id, attempts) do
    session_state = Session.Server.get_state(session)

    case Map.fetch(session_state.active_runs, run_id) do
      {:ok, run_pid} ->
        {:ok, run_pid}

      :error ->
        Process.sleep(5)
        lookup_run_pid(session, run_id, attempts - 1)
    end
  end

  defp emit_driver_error(run_pid, state, %Error{} = error) when is_pid(run_pid) do
    Run.Server.ingest_event(
      run_pid,
      %Event{
        id: Event.generate_id(),
        kind: :error,
        run_id: state.run_id,
        session_id: state.session_id,
        provider: state.provider,
        payload: %ASM.Message.Error{
          severity: :error,
          message: error.message,
          kind: error.kind
        },
        timestamp: DateTime.utc_now()
      }
    )
  end

  defp partition_opts(opts) do
    {stream_opts, rest} = Keyword.split(opts, @stream_keys)
    {run_opts, provider_opts} = Keyword.split(rest, @run_keys)
    {stream_opts, run_opts, provider_opts}
  end

  defp merge_opts(base, override) do
    Keyword.merge(base, override, fn
      :driver_opts, left, right -> merge_keyword_list(left, right)
      :run_module_opts, left, right -> merge_keyword_list(left, right)
      _key, _left, right -> right
    end)
  end

  defp merge_keyword_list(left, right) when is_list(left) and is_list(right),
    do: Keyword.merge(left, right)

  defp merge_keyword_list(_left, right) when is_list(right), do: right
  defp merge_keyword_list(left, _right) when is_list(left), do: left
  defp merge_keyword_list(_left, _right), do: []

  defp reduce_event(%Event{} = event, nil) do
    Run.State.new(run_id: event.run_id, session_id: event.session_id, provider: provider(event))
    |> Map.put(:started_at, event.timestamp)
    |> Run.EventReducer.apply_event!(event)
  end

  defp reduce_event(%Event{} = event, %Run.State{} = run_state) do
    Run.EventReducer.apply_event!(run_state, event)
  end

  defp provider(%Event{provider: nil}), do: :unknown
  defp provider(%Event{provider: provider}), do: provider

  defp runtime_error(message) do
    Error.new(:runtime, :runtime, message)
  end

  defp await_session_cleanup(session, run_id, timeout_ms) do
    attempts =
      timeout_ms
      |> min(2_000)
      |> div(10)
      |> max(1)

    do_await_session_cleanup(session, run_id, attempts)
  end

  defp do_await_session_cleanup(_session, _run_id, 0), do: :ok

  defp do_await_session_cleanup(session, run_id, attempts) do
    %{active_runs: active_runs} = Session.Server.get_state(session)

    if Map.has_key?(active_runs, run_id) do
      Process.sleep(10)
      do_await_session_cleanup(session, run_id, attempts - 1)
    else
      :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp receive_timeout(%{run_pid: nil, started?: false} = state) do
    case state.queue_timeout_ms do
      :infinity -> :infinity
      timeout_ms -> max(timeout_ms - elapsed_queue_ms(state), 0)
    end
  end

  defp receive_timeout(state), do: state.timeout_ms

  defp elapsed_queue_ms(%{queue_started_at_ms: nil}), do: 0

  defp elapsed_queue_ms(%{queue_started_at_ms: started_at_ms}) do
    max(monotonic_ms() - started_at_ms, 0)
  end

  defp timeout_error(%{run_pid: nil, started?: false} = state) do
    Error.new(
      :timeout,
      :runtime,
      "stream timeout waiting for queued run #{state.run_id} to start"
    )
  end

  defp timeout_error(state) do
    Error.new(
      :timeout,
      :runtime,
      "stream timeout waiting for run #{state.run_id} events"
    )
  end

  defp normalize_queue_timeout(:infinity), do: :infinity
  defp normalize_queue_timeout(value) when is_integer(value) and value > 0, do: value
  defp normalize_queue_timeout(_), do: :infinity

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp extract_text_blocks(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %Content.Text{text: text} when is_binary(text) -> [text]
      _other -> []
    end)
  end

  defp extract_text_blocks(_), do: []
end
