defmodule ASM.Run.Server do
  @moduledoc """
  Minimal per-run worker for foundation queue/lifecycle integration.

  Full streaming and reducer behavior is implemented in later phases.
  """

  use GenServer, restart: :temporary

  alias ASM.{Control, Error, Event, Message, Run}

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

  @impl true
  def init(opts) do
    state = Run.State.new(opts)
    {:ok, state, {:continue, :bootstrap}}
  end

  @impl true
  def handle_continue(:bootstrap, state) do
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
    {:reply, state, state}
  end

  @impl true
  def handle_cast({:ingest_event, %Event{} = event}, state) do
    case apply_pipeline(state, event) do
      {:ok, events, state} ->
        state = process_events(state, events)

        if Run.EventReducer.final?(state) do
          finish_run(state)
        else
          {:noreply, state}
        end

      {:error, %Error{} = error, state} ->
        error_event =
          envelope(state, :error, %Message.Error{
            severity: :error,
            message: error.message,
            kind: error.kind
          })

        state = process_events(state, [error_event])

        if Run.EventReducer.final?(state) do
          finish_run(state)
        else
          {:noreply, state}
        end
    end
  end

  def handle_cast(:interrupt, state) do
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

  @impl true
  def terminate(_reason, state) do
    cleanup_approval_timers(state)
    :ok
  end

  defp finish_run(state) do
    state
    |> cleanup_approvals_in_session()
    |> cleanup_approval_timers()

    notify_done(state)
    {:stop, :normal, state}
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

      fanout(acc, event)
      maybe_execute_tool(acc, event)
    end)
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
end
