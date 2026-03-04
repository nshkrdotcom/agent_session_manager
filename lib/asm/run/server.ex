defmodule ASM.Run.Server do
  @moduledoc """
  Per-run worker that owns run lifecycle, parser dispatch, and stream fanout.
  """

  use GenServer, restart: :temporary

  alias ASM.{Control, Error, Event, Message, Provider, Run, Transport}
  alias ASM.Transport.Cleanup, as: TransportCleanup

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec interrupt(GenServer.server()) :: :ok
  def interrupt(server) do
    GenServer.cast(server, :interrupt)
    :ok
  end

  @spec ingest_event(GenServer.server(), Event.t()) :: :ok
  def ingest_event(server, %Event{} = event) do
    GenServer.cast(server, {:ingest_event, event})
    :ok
  end

  @spec get_state(GenServer.server()) :: Run.State.t()
  def get_state(server), do: GenServer.call(server, :get_state)

  @spec resolve_approval(GenServer.server(), String.t(), :allow | :deny) :: :ok
  def resolve_approval(server, approval_id, decision) do
    GenServer.cast(server, {:resolve_approval, approval_id, decision})
    :ok
  end

  @spec attach_transport(GenServer.server(), pid()) :: :ok | {:error, Error.t()}
  def attach_transport(server, transport_pid) when is_pid(transport_pid) do
    GenServer.call(server, {:attach_transport, transport_pid})
  end

  @impl true
  def init(opts) do
    state = Run.State.new(opts)

    provider_parser =
      Keyword.get(opts, :provider_parser) || resolve_provider_parser(state.provider)

    {:ok, %{state | provider_parser: provider_parser}, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
    _ = ASM.Telemetry.run_started(state.session_id, state.run_id, state.provider)

    event =
      envelope(state, :run_started, %Control.RunLifecycle{
        status: :started,
        summary: %{prompt: state.prompt}
      })

    next_state = Run.EventReducer.apply_event!(state, event)
    fanout(next_state, event)

    {:noreply, next_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, Run.State.materialize(state), state}
  end

  def handle_call({:attach_transport, transport_pid}, _from, state) do
    case do_attach_transport(state, transport_pid) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, %Error{} = error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_cast({:ingest_event, %Event{} = event}, state) do
    consume_event(state, event)
  end

  def handle_cast(:interrupt, state) do
    maybe_interrupt_transport(state)

    event =
      envelope(state, :error, %Message.Error{
        severity: :warning,
        message: "Run interrupted",
        kind: :user_cancelled
      })

    next_state =
      state
      |> Run.EventReducer.apply_event!(event)
      |> Map.put(:status, :interrupted)
      |> Map.put(:finished_at, DateTime.utc_now())
      |> Map.put(:error, Error.new(:user_cancelled, :runtime, "Run interrupted"))

    fanout(next_state, event)
    finish_run(next_state)
  end

  def handle_cast({:resolve_approval, approval_id, decision}, state) do
    if Map.has_key?(state.pending_approvals, approval_id) do
      state = clear_approval_timer(state, approval_id)
      notify_session(state, {:clear_approval, approval_id})

      event =
        envelope(state, :approval_resolved, %Control.ApprovalResolution{
          approval_id: approval_id,
          decision: decision
        })

      next_state = Run.EventReducer.apply_event!(state, event)
      fanout(next_state, event)

      {:noreply, next_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:transport_message, raw_map}, state) when is_map(raw_map) do
    case parse_transport_map(state, raw_map) do
      {:ok, kind, payload} ->
        consume_event(state, envelope(state, kind, payload))

      {:error, %Error{} = error} ->
        consume_event(state, parser_error_event(state, error))
    end
  end

  def handle_info({:transport_error, reason}, state) do
    consume_event(state, transport_error_event(state, reason))
  end

  def handle_info({:transport_exit, status, diagnostics}, state) when is_integer(status) do
    terminal_event =
      if status == 0 do
        envelope(state, :run_completed, %Control.RunLifecycle{
          status: :completed,
          summary: %{source: :transport_exit}
        })
      else
        envelope(
          state,
          :error,
          %Message.Error{
            severity: :error,
            message:
              "provider process exited with status #{status}#{diagnostic_suffix(diagnostics)}",
            kind: :transport_error
          }
        )
      end

    consume_event(state, terminal_event)
  end

  def handle_info({:approval_timeout, approval_id}, state) do
    if Map.has_key?(state.pending_approvals, approval_id) do
      state = clear_approval_timer(state, approval_id)
      notify_session(state, {:clear_approval, approval_id})

      event =
        envelope(state, :approval_resolved, %Control.ApprovalResolution{
          approval_id: approval_id,
          decision: :deny,
          reason: "timeout"
        })

      next_state = Run.EventReducer.apply_event!(state, event)
      fanout(next_state, event)

      {:noreply, next_state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %Run.State{transport_ref: ref} = state) do
    next_state = %{state | transport_pid: nil, transport_ref: nil}

    cond do
      Run.EventReducer.final?(next_state) ->
        {:noreply, next_state}

      reason in [:normal, :shutdown] ->
        consume_event(
          next_state,
          envelope(next_state, :run_completed, %Control.RunLifecycle{
            status: :completed,
            summary: %{source: :transport_down}
          })
        )

      true ->
        consume_event(
          next_state,
          envelope(
            next_state,
            :error,
            %Message.Error{
              severity: :error,
              message: "transport crashed: #{inspect(reason)}",
              kind: :transport_error
            }
          )
        )
    end
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_approval_timers(state)
    :ok
  end

  defp do_attach_transport(%Run.State{transport_pid: nil} = state, transport_pid) do
    timeout_ms = transport_call_timeout_ms(state)

    case Transport.attach(transport_pid, self(), timeout_ms) do
      {:ok, :attached} ->
        ref = Process.monitor(transport_pid)
        next_state = %{state | transport_pid: transport_pid, transport_ref: ref}
        demand_next(next_state)
        {:ok, next_state}

      {:error, :busy} ->
        {:error, Error.new(:transport_busy, :transport, "Transport is already leased")}

      {:error, reason} ->
        {:error,
         Error.new(
           :transport_error,
           :transport,
           "Transport attach failed: #{inspect(reason)}",
           cause: reason
         )}
    end
  catch
    :exit, reason ->
      {:error,
       Error.new(
         :transport_error,
         :transport,
         "Transport attach failed: #{inspect(reason)}",
         cause: reason
       )}
  end

  defp do_attach_transport(%Run.State{transport_pid: transport_pid} = state, transport_pid) do
    {:ok, state}
  end

  defp do_attach_transport(%Run.State{}, _transport_pid) do
    {:error,
     Error.new(:transport_busy, :transport, "Run already attached to a different transport")}
  end

  defp consume_event(state, %Event{} = event) do
    case apply_pipeline(state, event) do
      {:ok, events, state} ->
        next_state = process_events(state, events)

        if Run.EventReducer.final?(next_state) do
          finish_run(next_state)
        else
          demand_next(next_state)
          {:noreply, next_state}
        end

      {:error, %Error{} = error, state} ->
        error_event =
          envelope(state, :error, %Message.Error{
            severity: :error,
            message: error.message,
            kind: error.kind
          })

        next_state = process_events(state, [error_event])

        if Run.EventReducer.final?(next_state) do
          finish_run(next_state)
        else
          demand_next(next_state)
          {:noreply, next_state}
        end
    end
  end

  defp parse_transport_map(%Run.State{provider_parser: parser}, raw_map) when is_atom(parser) do
    case parser.parse(raw_map) do
      {:ok, {kind, payload}} ->
        {:ok, kind, payload}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:parse_error, :parser, "parser failed: #{inspect(reason)}", cause: reason)}
    end
  end

  defp parse_transport_map(_state, _raw_map) do
    {:error, Error.new(:parse_error, :parser, "run has no parser module configured")}
  end

  defp parser_error_event(state, %Error{} = error) do
    envelope(
      state,
      :error,
      %Message.Error{
        severity: :error,
        message: error.message,
        kind: :parse_error
      }
    )
  end

  defp transport_error_event(state, {:timeout, timeout_ms}) do
    envelope(
      state,
      :error,
      %Message.Error{
        severity: :error,
        message: "provider command timed out after #{timeout_ms}ms",
        kind: :timeout
      }
    )
  end

  defp transport_error_event(state, {:parse_error, reason, _line}) do
    envelope(
      state,
      :error,
      %Message.Error{
        severity: :error,
        message: "failed to parse provider output: #{inspect(reason)}",
        kind: :parse_error
      }
    )
  end

  defp transport_error_event(state, :buffer_overflow) do
    envelope(
      state,
      :error,
      %Message.Error{
        severity: :error,
        message: "transport buffer overflow",
        kind: :transport_error
      }
    )
  end

  defp transport_error_event(state, reason) do
    envelope(
      state,
      :error,
      %Message.Error{
        severity: :error,
        message: "transport error: #{inspect(reason)}",
        kind: :transport_error
      }
    )
  end

  defp finish_run(state) do
    _ = ASM.Telemetry.run_completed(state.session_id, state.run_id, state.provider, state.status)

    state
    |> cleanup_approvals_in_session()
    |> cleanup_approval_timers()
    |> cleanup_transport()

    notify_done(state)
    {:stop, :normal, state}
  end

  defp cleanup_transport(%Run.State{transport_pid: nil} = state), do: state

  defp cleanup_transport(
         %Run.State{transport_pid: transport_pid, transport_ref: transport_ref} = state
       ) do
    timeout_ms = transport_call_timeout_ms(state)

    monitor_ref = transport_ref || Process.monitor(transport_pid)

    maybe_interrupt_before_close(state, transport_pid, timeout_ms)
    _ = Transport.detach(transport_pid, self(), timeout_ms)

    _ =
      TransportCleanup.close(
        transport_pid,
        monitor_ref: monitor_ref,
        close_fun: fn pid -> Transport.close(pid, timeout_ms) end,
        close_grace_ms: timeout_ms
      )

    %{state | transport_pid: nil, transport_ref: nil}
  catch
    :exit, _ -> %{state | transport_pid: nil, transport_ref: nil}
  end

  defp fanout(%Run.State{subscriber: nil}, _event), do: :ok

  defp fanout(%Run.State{subscriber: subscriber, run_id: run_id}, %Event{} = event) do
    send(subscriber, {:asm_run_event, run_id, event})
    :ok
  end

  defp notify_done(%Run.State{subscriber: nil}), do: :ok

  defp notify_done(%Run.State{subscriber: subscriber, run_id: run_id}) do
    send(subscriber, {:asm_run_done, run_id})
    :ok
  end

  defp maybe_handle_approval_request(
         %Run.State{} = next_state,
         %Event{kind: :approval_requested, payload: %Control.ApprovalRequest{} = payload}
       ) do
    notify_session(next_state, {:register_approval, payload.approval_id, self()})

    timer_ref =
      Process.send_after(
        self(),
        {:approval_timeout, payload.approval_id},
        next_state.approval_timeout_ms
      )

    put_in(next_state.approval_timers[payload.approval_id], timer_ref)
  end

  defp maybe_handle_approval_request(state, _event), do: state

  defp cleanup_approvals_in_session(state) do
    Enum.each(Map.keys(state.pending_approvals), fn approval_id ->
      notify_session(state, {:clear_approval, approval_id})
    end)

    state
  end

  defp cleanup_approval_timers(state) do
    Enum.each(state.approval_timers, fn {_approval_id, timer_ref} ->
      Process.cancel_timer(timer_ref, async: true, info: false)
    end)

    state
  end

  defp clear_approval_timer(state, approval_id) do
    case Map.pop(state.approval_timers, approval_id) do
      {nil, timers} ->
        %{state | approval_timers: timers}

      {timer_ref, timers} ->
        Process.cancel_timer(timer_ref, async: true, info: false)
        %{state | approval_timers: timers}
    end
  end

  defp notify_session(%Run.State{session_pid: nil}, _message), do: :ok

  defp notify_session(%Run.State{session_pid: session_pid}, message) when is_pid(session_pid) do
    send(session_pid, message)
    :ok
  end

  defp maybe_execute_tool(
         %Run.State{} = state,
         %Event{kind: :tool_use, payload: %Message.ToolUse{} = tool_use}
       ) do
    result_payload =
      if is_atom(state.tool_executor) and
           Code.ensure_loaded?(state.tool_executor) and
           function_exported?(state.tool_executor, :execute, 2) do
        state.tool_executor.execute(tool_use, state)
      else
        %Message.ToolResult{
          tool_id: tool_use.tool_id,
          content: "invalid_tool_executor",
          is_error: true
        }
      end

    result_event = envelope(state, :tool_result, result_payload)
    next_state = Run.EventReducer.apply_event!(state, result_event)
    fanout(next_state, result_event)
    next_state
  end

  defp maybe_execute_tool(state, _event), do: state

  defp apply_pipeline(%Run.State{pipeline: []} = state, event) do
    {:ok, [event], state}
  end

  defp apply_pipeline(%Run.State{} = state, event) do
    case ASM.Pipeline.run(event, state.pipeline, state.pipeline_ctx) do
      {:ok, events, next_ctx} ->
        {:ok, events, %{state | pipeline_ctx: next_ctx}}

      {:error, %Error{} = error, next_ctx} ->
        {:error, error, %{state | pipeline_ctx: next_ctx}}
    end
  end

  defp process_events(state, events) do
    Enum.reduce(events, state, fn event, acc ->
      acc =
        acc
        |> Run.EventReducer.apply_event!(event)
        |> maybe_handle_approval_request(event)
        |> maybe_forward_cost_update(event)

      fanout(acc, event)
      maybe_execute_tool(acc, event)
    end)
  end

  defp maybe_forward_cost_update(
         %Run.State{} = state,
         %Event{kind: :cost_update, payload: %Control.CostUpdate{} = payload}
       ) do
    notify_session(state, {:cost_update, payload})
    state
  end

  defp maybe_forward_cost_update(state, _event), do: state

  defp maybe_interrupt_transport(%Run.State{transport_pid: nil}), do: :ok

  defp maybe_interrupt_transport(%Run.State{transport_pid: transport_pid} = state) do
    _ = Transport.interrupt(transport_pid, transport_call_timeout_ms(state))
    :ok
  catch
    :exit, _ -> :ok
  end

  defp demand_next(%Run.State{transport_pid: nil}), do: :ok

  defp demand_next(%Run.State{transport_pid: transport_pid}) when is_pid(transport_pid) do
    Transport.demand(transport_pid, self(), 1)
  end

  defp envelope(state, kind, payload) do
    %Event{
      id: Event.generate_id(),
      kind: kind,
      run_id: state.run_id,
      session_id: state.session_id,
      provider: state.provider,
      payload: payload,
      timestamp: DateTime.utc_now()
    }
  end

  defp resolve_provider_parser(provider_name) do
    provider_name
    |> Provider.resolve!()
    |> Map.fetch!(:parser)
  end

  defp diagnostic_suffix([]), do: ""
  defp diagnostic_suffix(lines), do: ": " <> Enum.join(lines, " | ")

  defp maybe_interrupt_before_close(
         %Run.State{provider: provider_name},
         transport_pid,
         timeout_ms
       ) do
    case Provider.resolve(provider_name) do
      {:ok, %Provider{profile: %{control_mode: :stdio_bidirectional}}} ->
        _ = Transport.interrupt(transport_pid, timeout_ms)
        :ok

      _ ->
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp transport_call_timeout_ms(%Run.State{transport_call_timeout_ms: timeout_ms})
       when is_integer(timeout_ms) and timeout_ms > 0,
       do: timeout_ms

  defp transport_call_timeout_ms(_state), do: 5_000
end
