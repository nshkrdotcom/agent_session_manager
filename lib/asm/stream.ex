defmodule ASM.Stream do
  @moduledoc """
  Stream helpers for run event consumption and final result projection.
  """

  alias ASM.{Error, Event, Run, Session}

  @stream_keys [:driver, :driver_opts, :stream_timeout_ms]
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
          timeout_ms: pos_integer(),
          done?: boolean()
        }

  @spec create(GenServer.server(), String.t(), keyword()) :: Enumerable.t()
  def create(session, prompt, opts \\ []) when is_binary(prompt) and is_list(opts) do
    Stream.resource(
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

  defp init_stream(session, prompt, opts) do
    session_state = Session.Server.get_state(session)
    {stream_opts, run_opts, provider_opts} = partition_opts(opts)

    run_opts =
      run_opts
      |> Keyword.update(:run_module_opts, [subscriber: self()], fn module_opts ->
        Keyword.put_new(module_opts, :subscriber, self())
      end)

    case Session.Server.submit_run(session, prompt, run_opts) do
      {:ok, run_id, run_pid_or_queued} ->
        state = %{
          session: session,
          session_id: session_state.session_id,
          provider: session_state.provider.name,
          prompt: prompt,
          provider_opts: provider_opts,
          run_id: run_id,
          run_pid: if(is_pid(run_pid_or_queued), do: run_pid_or_queued, else: nil),
          driver: Keyword.get(stream_opts, :driver, ASM.Stream.CLIDriver),
          driver_opts: Keyword.get(stream_opts, :driver_opts, []),
          driver_pid: nil,
          timeout_ms: max(Keyword.get(stream_opts, :stream_timeout_ms, 60_000), 1),
          done?: false
        }

        maybe_start_driver(state)

      {:error, %Error{} = error} ->
        raise error
    end
  end

  defp next_event(%{done?: true} = state), do: {:halt, state}

  defp next_event(state) do
    receive do
      {:asm_run_event, run_id, %Event{} = event} when run_id == state.run_id ->
        {[event], maybe_start_driver_on_bootstrap(state, event)}

      {:asm_run_done, run_id} when run_id == state.run_id ->
        await_session_cleanup(state.session, state.run_id, state.timeout_ms)
        {:halt, %{state | done?: true}}

      _other ->
        next_event(state)
    after
      state.timeout_ms ->
        raise Error.new(
                :timeout,
                :runtime,
                "stream timeout waiting for run #{state.run_id} events"
              )
    end
  end

  defp close_stream(state) do
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
        %{state | driver_pid: pid}

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
      {:ok, run_pid} -> maybe_start_driver(%{state | run_pid: run_pid})
      :error -> state
    end
  end

  defp maybe_start_driver_on_bootstrap(state, _event), do: state

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
end
