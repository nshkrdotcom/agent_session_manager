defmodule ASM.Stream do
  @moduledoc """
  Stream helpers for run event consumption and final result projection.
  """

  alias ASM.{Content, Error, Event, Run, Session}
  alias ASM.Execution.Config

  @stream_keys [
    :execution_mode,
    :stream_timeout_ms,
    :queue_timeout_ms,
    :transport_call_timeout_ms,
    :execution_surface,
    :execution_environment,
    :workspace_root,
    :allowed_tools,
    :approval_posture,
    :permission_mode,
    :lane,
    :driver_opts,
    :remote_node,
    :remote_cookie,
    :remote_connect_timeout_ms,
    :remote_rpc_timeout_ms,
    :remote_boot_lease_timeout_ms,
    :remote_bootstrap_mode,
    :remote_cwd,
    :remote_transport_call_timeout_ms
  ]

  @run_keys [
    :run_id,
    :continuation,
    :intervention_for_run_id,
    :run_module,
    :run_module_opts,
    :pipeline,
    :pipeline_ctx,
    :tools,
    :approval_timeout_ms,
    :backend_module,
    :backend_opts,
    :metadata
  ]

  @type stream_state :: %{
          session: GenServer.server(),
          run_id: String.t(),
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
      %Event{} = event ->
        case Event.text_delta(event) do
          nil -> []
          delta -> [delta]
        end

      _other ->
        []
    end)
  end

  @spec text_content(Enumerable.t()) :: Enumerable.t()
  def text_content(events) do
    Elixir.Stream.flat_map(events, fn
      %Event{} = event ->
        case Event.assistant_text(event) do
          nil -> []
          text -> [text]
        end

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

    execution_config =
      resolve_execution_config!(
        session_state.provider.name,
        session_stream_opts,
        call_stream_opts
      )

    provider_opts =
      resolve_provider_opts!(
        session_state,
        merge_opts(session_provider_opts, call_provider_opts),
        execution_config
      )

    run_opts =
      run_opts
      |> Keyword.put(:execution_config, execution_config)
      |> Keyword.put(:provider_opts, provider_opts)
      |> Keyword.put(:lane, Keyword.get(stream_opts, :lane, :auto))
      |> Keyword.update(:run_module_opts, [subscriber: self()], fn module_opts ->
        Keyword.put_new(module_opts, :subscriber, self())
      end)

    case Session.Server.submit_run(session, prompt, run_opts) do
      {:ok, run_id, run_pid_or_queued} ->
        %{
          session: session,
          run_id: run_id,
          timeout_ms: max(Keyword.get(stream_opts, :stream_timeout_ms, 60_000), 1),
          queue_timeout_ms:
            normalize_queue_timeout(Keyword.get(stream_opts, :queue_timeout_ms, :infinity)),
          queue_started_at_ms: if(is_pid(run_pid_or_queued), do: nil, else: monotonic_ms()),
          started?: is_pid(run_pid_or_queued),
          done?: false
        }

      {:error, %Error{} = error} ->
        raise error
    end
  end

  defp resolve_execution_config!(provider, session_stream_opts, call_stream_opts) do
    case Config.resolve(session_stream_opts, call_stream_opts, provider: provider) do
      {:ok, cfg} -> cfg
      {:error, %Error{} = error} -> raise error
    end
  end

  defp resolve_provider_opts!(session_state, provider_opts, execution_config) do
    validated_opts =
      case ASM.Options.validate(
             Keyword.put(provider_opts, :provider, session_state.provider.name),
             session_state.provider.options_schema
           ) do
        {:ok, validated} -> Keyword.delete(validated, :provider)
        {:error, %Error{} = error} -> raise error
      end

    finalized_opts =
      validated_opts
      |> maybe_override_permission_modes(execution_config)

    case ASM.Options.finalize_provider_opts(session_state.provider.name, finalized_opts) do
      {:ok, finalized} -> finalized
      {:error, %Error{} = error} -> raise error
    end
  end

  defp maybe_override_permission_modes(provider_opts, execution_config)
       when is_list(provider_opts) and is_map(execution_config) do
    permission_mode = Config.to_execution_environment(execution_config).permission_mode
    provider_permission_mode = Map.get(execution_config, :provider_permission_mode)

    provider_opts
    |> maybe_put_override(:permission_mode, permission_mode)
    |> maybe_put_override(:provider_permission_mode, provider_permission_mode)
  end

  defp maybe_put_override(provider_opts, _key, nil), do: provider_opts
  defp maybe_put_override(provider_opts, key, value), do: Keyword.put(provider_opts, key, value)

  defp next_event(%{done?: true} = state), do: {:halt, state}

  defp next_event(state) do
    timeout = receive_timeout(state)

    receive do
      {:asm_run_event, run_id, %Event{} = event} when run_id == state.run_id ->
        next_state = maybe_mark_started(state, event)
        {[event], next_state}

      {:asm_run_done, run_id} when run_id == state.run_id ->
        await_session_cleanup(state.session, state.run_id, state.timeout_ms)
        {:halt, %{state | done?: true}}

      _other ->
        next_event(state)
    after
      timeout ->
        raise timeout_error(state)
    end
  end

  defp close_stream(state) do
    unless state.done? do
      _ = Session.Server.cancel_run(state.session, state.run_id)
    end

    :ok
  end

  defp partition_opts(opts) do
    {stream_opts, rest} = Keyword.split(opts, @stream_keys)
    {run_opts, provider_opts} = Keyword.split(rest, run_keys())
    {stream_opts, run_opts, provider_opts}
  end

  defp run_keys, do: @run_keys ++ ASM.RuntimeAuth.option_keys()

  defp merge_opts(base, override) do
    Keyword.merge(base, override, fn
      :run_module_opts, left, right -> merge_keyword_list(left, right)
      _key, _left, right -> right
    end)
  end

  defp merge_keyword_list(left, right) when is_list(left) and is_list(right),
    do: Keyword.merge(left, right)

  defp merge_keyword_list(_left, right) when is_list(right), do: right
  defp merge_keyword_list(left, _right) when is_list(left), do: left
  defp merge_keyword_list(_left, _right), do: []

  defp maybe_mark_started(state, %Event{kind: :run_started}) do
    %{state | started?: true, queue_started_at_ms: nil}
  end

  defp maybe_mark_started(state, _event), do: state

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

  defp receive_timeout(%{started?: false} = state) do
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

  defp timeout_error(%{started?: false} = state) do
    Error.new(
      :timeout,
      :runtime,
      "stream timeout waiting for queued run #{state.run_id} to start"
    )
  end

  defp timeout_error(state) do
    Error.new(:timeout, :runtime, "stream timeout waiting for run #{state.run_id} events")
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
