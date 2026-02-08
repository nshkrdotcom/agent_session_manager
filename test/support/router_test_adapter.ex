defmodule AgentSessionManager.Test.RouterTestAdapter do
  @moduledoc false

  @behaviour AgentSessionManager.Ports.ProviderAdapter

  use GenServer

  alias AgentSessionManager.Core.{Capability, Error}
  alias AgentSessionManager.Ports.ProviderAdapter

  @type outcome ::
          {:ok, ProviderAdapter.run_result()}
          | {:error, Error.t()}
          | {:sleep, pos_integer(), {:ok, ProviderAdapter.run_result()} | {:error, Error.t()}}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @spec stop(GenServer.server()) :: :ok
  def stop(server) do
    GenServer.stop(server, :normal)
  end

  @spec set_outcomes(GenServer.server(), [outcome()]) :: :ok
  def set_outcomes(server, outcomes) when is_list(outcomes) do
    GenServer.call(server, {:set_outcomes, outcomes})
  end

  @spec execute_count(GenServer.server()) :: non_neg_integer()
  def execute_count(server) do
    GenServer.call(server, :execute_count)
  end

  @spec execute_calls(GenServer.server()) :: [String.t()]
  def execute_calls(server) do
    GenServer.call(server, :execute_calls)
  end

  @spec cancelled_runs(GenServer.server()) :: [String.t()]
  def cancelled_runs(server) do
    GenServer.call(server, :cancelled_runs)
  end

  @spec last_execute_opts(GenServer.server()) :: keyword()
  def last_execute_opts(server) do
    GenServer.call(server, :last_execute_opts)
  end

  @impl ProviderAdapter
  def name(adapter) do
    GenServer.call(adapter, :name)
  end

  @impl ProviderAdapter
  def capabilities(adapter) do
    GenServer.call(adapter, :capabilities)
  end

  @impl ProviderAdapter
  def execute(adapter, run, session, opts \\ []) do
    timeout = ProviderAdapter.resolve_execute_timeout(opts)
    GenServer.call(adapter, {:execute, run, session, opts}, timeout)
  end

  @impl ProviderAdapter
  def cancel(adapter, run_id) do
    GenServer.call(adapter, {:cancel, run_id})
  end

  @impl ProviderAdapter
  def validate_config(_adapter, config) when is_map(config), do: :ok

  @impl ProviderAdapter
  def validate_config(_adapter, _config) do
    {:error, Error.new(:validation_error, "Invalid adapter config")}
  end

  @impl GenServer
  def init(opts) do
    provider_name = Keyword.get(opts, :provider_name, "router-test")
    outcomes = Keyword.get(opts, :outcomes, [{:ok, default_result(provider_name)}])
    capabilities = Keyword.get(opts, :capabilities, default_capabilities())
    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok,
     %{
       provider_name: provider_name,
       capabilities: capabilities,
       outcomes: outcomes,
       task_supervisor: task_supervisor,
       pending_tasks: %{},
       run_tasks: %{},
       execute_calls: [],
       cancelled_runs: MapSet.new(),
       last_execute_opts: []
     }}
  end

  @impl GenServer
  def handle_call(:name, _from, state) do
    {:reply, state.provider_name, state}
  end

  def handle_call(:capabilities, _from, state) do
    {:reply, {:ok, state.capabilities}, state}
  end

  def handle_call({:execute, run, session, opts}, from, state) do
    {outcome, remaining_outcomes} = pop_outcome(state.outcomes, state.provider_name)
    adapter_pid = self()

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        execute_outcome(outcome, adapter_pid, run, session, opts)
      end)

    new_state = %{
      state
      | outcomes: remaining_outcomes,
        execute_calls: state.execute_calls ++ [run.id],
        last_execute_opts: opts,
        pending_tasks: Map.put(state.pending_tasks, task.ref, %{run_id: run.id, from: from}),
        run_tasks: Map.put(state.run_tasks, run.id, %{task_ref: task.ref, task_pid: task.pid})
    }

    {:noreply, new_state}
  end

  def handle_call({:cancel, run_id}, _from, state) do
    updated_state = %{state | cancelled_runs: MapSet.put(state.cancelled_runs, run_id)}

    if run_task = Map.get(updated_state.run_tasks, run_id) do
      send(run_task.task_pid, {:cancelled_notification, run_id})
    end

    {:reply, {:ok, run_id}, updated_state}
  end

  def handle_call({:set_outcomes, outcomes}, _from, state) do
    {:reply, :ok, %{state | outcomes: outcomes}}
  end

  def handle_call(:execute_count, _from, state) do
    {:reply, length(state.execute_calls), state}
  end

  def handle_call(:execute_calls, _from, state) do
    {:reply, state.execute_calls, state}
  end

  def handle_call(:cancelled_runs, _from, state) do
    {:reply, MapSet.to_list(state.cancelled_runs), state}
  end

  def handle_call(:last_execute_opts, _from, state) do
    {:reply, state.last_execute_opts, state}
  end

  @impl GenServer
  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    case Map.pop(state.pending_tasks, task_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {%{run_id: run_id, from: from}, pending_tasks} ->
        Process.demonitor(task_ref, [:flush])
        GenServer.reply(from, result)
        run_tasks = Map.delete(state.run_tasks, run_id)
        {:noreply, %{state | pending_tasks: pending_tasks, run_tasks: run_tasks}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, task_ref, :process, _pid, reason}, state) do
    case Map.pop(state.pending_tasks, task_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {%{run_id: run_id, from: from}, pending_tasks} ->
        Process.demonitor(task_ref, [:flush])
        error = Error.new(:internal_error, "Execution task crashed: #{inspect(reason)}")
        GenServer.reply(from, {:error, error})
        run_tasks = Map.delete(state.run_tasks, run_id)
        {:noreply, %{state | pending_tasks: pending_tasks, run_tasks: run_tasks}}
    end
  end

  defp pop_outcome([outcome | rest], _provider_name), do: {outcome, rest}
  defp pop_outcome([], provider_name), do: {{:ok, default_result(provider_name)}, []}

  defp execute_outcome(outcome, adapter_pid, run, session, opts) do
    event_callback = Keyword.get(opts, :event_callback)
    emit_run_started(event_callback, run, session)

    case outcome do
      {:sleep, duration_ms, delayed_outcome} when is_integer(duration_ms) and duration_ms > 0 ->
        wait_result = wait_for_cancellation(duration_ms, run.id)

        case wait_result do
          :cancelled ->
            emit_run_cancelled(event_callback, run, session)
            {:error, Error.new(:cancelled, "Run cancelled")}

          :ready ->
            finalize_outcome(delayed_outcome, event_callback, adapter_pid, run, session)
        end

      other ->
        finalize_outcome(other, event_callback, adapter_pid, run, session)
    end
  end

  defp finalize_outcome({:ok, result}, event_callback, _adapter_pid, run, session) do
    emit_scripted_events(event_callback, run, session, result)
    emit_message_received(event_callback, run, session, result)
    emit_run_completed(event_callback, run, session)
    {:ok, result}
  end

  defp finalize_outcome({:error, %Error{} = error}, event_callback, _adapter_pid, run, session) do
    emit_run_failed(event_callback, run, session, error)
    {:error, error}
  end

  defp finalize_outcome({:error, error}, event_callback, _adapter_pid, run, session) do
    normalized = Error.new(:provider_error, inspect(error))
    emit_run_failed(event_callback, run, session, normalized)
    {:error, normalized}
  end

  defp wait_for_cancellation(duration_ms, run_id) do
    receive do
      {:cancelled_notification, ^run_id} ->
        :cancelled
    after
      duration_ms ->
        :ready
    end
  end

  defp emit_run_started(nil, _run, _session), do: :ok

  defp emit_run_started(callback, run, session) when is_function(callback, 1) do
    callback.(%{
      type: :run_started,
      session_id: session.id,
      run_id: run.id,
      timestamp: DateTime.utc_now(),
      data: %{provider_session_id: "provider-session-#{run.id}", model: "router-test-model"}
    })
  end

  defp emit_message_received(nil, _run, _session, _result), do: :ok

  defp emit_message_received(callback, run, session, result) when is_function(callback, 1) do
    content =
      result
      |> Map.get(:output, %{})
      |> Map.get(:content, "")

    callback.(%{
      type: :message_received,
      session_id: session.id,
      run_id: run.id,
      timestamp: DateTime.utc_now(),
      data: %{role: "assistant", content: content}
    })
  end

  defp emit_run_completed(nil, _run, _session), do: :ok

  defp emit_run_completed(callback, run, session) when is_function(callback, 1) do
    callback.(%{
      type: :run_completed,
      session_id: session.id,
      run_id: run.id,
      timestamp: DateTime.utc_now(),
      data: %{stop_reason: "end_turn"}
    })
  end

  defp emit_run_failed(nil, _run, _session, _error), do: :ok

  defp emit_run_failed(callback, run, session, error) when is_function(callback, 1) do
    callback.(%{
      type: :run_failed,
      session_id: session.id,
      run_id: run.id,
      timestamp: DateTime.utc_now(),
      data: %{error_code: error.code, error_message: error.message}
    })
  end

  defp emit_run_cancelled(nil, _run, _session), do: :ok

  defp emit_run_cancelled(callback, run, session) when is_function(callback, 1) do
    callback.(%{
      type: :run_cancelled,
      session_id: session.id,
      run_id: run.id,
      timestamp: DateTime.utc_now(),
      data: %{}
    })
  end

  defp emit_scripted_events(nil, _run, _session, _result), do: :ok

  defp emit_scripted_events(callback, run, session, result) when is_function(callback, 1) do
    result
    |> Map.get(:events, [])
    |> List.wrap()
    |> Enum.each(fn event ->
      callback.(normalize_scripted_event(event, run, session))
    end)
  end

  defp normalize_scripted_event(%{} = event, run, session) do
    %{
      type: Map.get(event, :type, :message_streamed),
      session_id: Map.get(event, :session_id, session.id),
      run_id: Map.get(event, :run_id, run.id),
      timestamp: Map.get(event, :timestamp, DateTime.utc_now()),
      data: Map.get(event, :data, %{})
    }
  end

  defp default_capabilities do
    [
      %Capability{name: "chat", type: :tool, enabled: true},
      %Capability{name: "sampling", type: :sampling, enabled: true}
    ]
  end

  defp default_result(provider_name) do
    %{
      output: %{provider: provider_name, content: "router test response"},
      token_usage: %{input_tokens: 10, output_tokens: 20},
      events: []
    }
  end
end
