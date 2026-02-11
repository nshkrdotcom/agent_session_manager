defmodule AgentSessionManager.Routing.ProviderRouter do
  @moduledoc """
  Provider router that implements the `ProviderAdapter` behaviour.

  The router selects a registered adapter by capability requirements,
  routing policy, and simple in-router health state. It supports retryable
  failover and run-to-adapter cancellation routing.

  ## Phase 2 Additions

  - **Weighted scoring** — when `strategy: :weighted`, candidates are ordered
    by score (static weight minus health penalty).
  - **Session stickiness** — pass `routing: [sticky_session_id: id]` to pin a
    session to a provider for continuity. The mapping expires after
    `sticky_ttl_ms` (default: 300 000 ms).
  - **Routing telemetry** — emits `[:agent_session_manager, :router, :attempt, ...]`
    events for each routing attempt.
  - **Circuit breaker** — optional per-adapter circuit breaker behind
    `circuit_breaker: true` configuration.
  """

  @behaviour AgentSessionManager.Ports.ProviderAdapter

  use GenServer

  alias AgentSessionManager.Config
  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Ports.ProviderAdapter
  alias AgentSessionManager.Routing.{CapabilityMatcher, CircuitBreaker, RoutingPolicy}

  @type adapter_id :: String.t()

  @type adapter_entry :: %{
          id: adapter_id(),
          adapter: ProviderAdapter.adapter(),
          opts: keyword()
        }

  @type health_entry :: %{
          failure_count: non_neg_integer(),
          last_failure_at: DateTime.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @spec register_adapter(GenServer.server(), adapter_id(), ProviderAdapter.adapter(), keyword()) ::
          :ok
  def register_adapter(server, id, adapter, opts \\ []) do
    GenServer.call(server, {:register_adapter, id, adapter, opts})
  end

  @spec unregister_adapter(GenServer.server(), adapter_id()) :: :ok
  def unregister_adapter(server, id) do
    GenServer.call(server, {:unregister_adapter, id})
  end

  @spec status(GenServer.server()) :: map()
  def status(server) do
    GenServer.call(server, :status)
  end

  @impl ProviderAdapter
  def name(adapter) when is_pid(adapter), do: GenServer.call(adapter, :name)

  def name(adapter) when is_atom(adapter) do
    if Process.whereis(adapter) do
      GenServer.call(adapter, :name)
    else
      Config.get(:default_router_name)
    end
  end

  @impl ProviderAdapter
  def capabilities(adapter) when is_pid(adapter), do: GenServer.call(adapter, :capabilities)

  def capabilities(adapter) when is_atom(adapter) do
    if Process.whereis(adapter) do
      GenServer.call(adapter, :capabilities)
    else
      {:ok, []}
    end
  end

  @impl ProviderAdapter
  def execute(adapter, run, session, opts \\ [])

  def execute(adapter, run, session, opts) when is_pid(adapter) do
    timeout = ProviderAdapter.resolve_execute_timeout(opts)
    GenServer.call(adapter, {:execute, run, session, opts}, timeout)
  end

  def execute(adapter, run, session, opts) when is_atom(adapter) do
    if Process.whereis(adapter) do
      timeout = ProviderAdapter.resolve_execute_timeout(opts)
      GenServer.call(adapter, {:execute, run, session, opts}, timeout)
    else
      {:error, Error.new(:provider_unavailable, "Provider router is not running")}
    end
  end

  @impl ProviderAdapter
  def cancel(adapter, run_id) when is_pid(adapter), do: GenServer.call(adapter, {:cancel, run_id})

  def cancel(adapter, run_id) when is_atom(adapter) do
    if Process.whereis(adapter) do
      GenServer.call(adapter, {:cancel, run_id})
    else
      {:error, Error.new(:run_not_found, "No active routed run found: #{run_id}")}
    end
  end

  @impl ProviderAdapter
  def validate_config(_adapter, config) when is_map(config), do: :ok

  @impl ProviderAdapter
  def validate_config(_adapter, _config) do
    {:error, Error.new(:validation_error, "Invalid provider router config")}
  end

  @impl GenServer
  def init(opts) do
    policy = RoutingPolicy.new(Keyword.get(opts, :policy, []))

    cooldown_ms =
      normalize_cooldown(
        Keyword.get(opts, :cooldown_ms, Config.get(:circuit_breaker_cooldown_ms))
      )

    circuit_breaker_enabled = Keyword.get(opts, :circuit_breaker, false) == true

    circuit_breaker_opts =
      Keyword.get(opts, :circuit_breaker_opts, [])
      |> normalize_cb_opts(cooldown_ms)

    {:ok, task_supervisor} = Task.Supervisor.start_link()

    {:ok,
     %{
       policy: policy,
       cooldown_ms: cooldown_ms,
       adapters: %{},
       health: %{},
       active_runs: %{},
       pending_tasks: %{},
       task_supervisor: task_supervisor,
       sticky_sessions: %{},
       sticky_ttl_ms:
         normalize_ttl(Keyword.get(opts, :sticky_ttl_ms, Config.get(:sticky_session_ttl_ms))),
       circuit_breaker_enabled: circuit_breaker_enabled,
       circuit_breaker_opts: circuit_breaker_opts,
       circuit_breakers: %{}
     }}
  end

  @impl GenServer
  def handle_call(:name, _from, state) do
    {:reply, Config.get(:default_router_name), state}
  end

  def handle_call(:capabilities, _from, state) do
    capabilities =
      state.adapters
      |> Map.values()
      |> Enum.reduce([], fn adapter_entry, acc ->
        acc ++ fetch_adapter_capabilities(adapter_entry.adapter)
      end)
      |> Enum.uniq_by(&{&1.type, &1.name, &1.enabled})

    {:reply, {:ok, capabilities}, state}
  end

  def handle_call({:register_adapter, id, adapter, opts}, _from, state) do
    adapter_id = normalize_adapter_id(id)

    if adapter_id == nil do
      {:reply, :ok, state}
    else
      adapter_entry = %{id: adapter_id, adapter: adapter, opts: opts}
      adapters = Map.put(state.adapters, adapter_id, adapter_entry)
      health = Map.put_new(state.health, adapter_id, default_health())

      circuit_breakers =
        if state.circuit_breaker_enabled do
          Map.put_new(
            state.circuit_breakers,
            adapter_id,
            CircuitBreaker.new(state.circuit_breaker_opts)
          )
        else
          state.circuit_breakers
        end

      {:reply, :ok,
       %{state | adapters: adapters, health: health, circuit_breakers: circuit_breakers}}
    end
  end

  def handle_call({:unregister_adapter, id}, _from, state) do
    adapter_id = normalize_adapter_id(id)
    adapters = Map.delete(state.adapters, adapter_id)
    health = Map.delete(state.health, adapter_id)
    circuit_breakers = Map.delete(state.circuit_breakers, adapter_id)

    active_runs =
      Enum.reduce(state.active_runs, %{}, fn {run_id, active_entry}, acc ->
        if active_entry.adapter_id == adapter_id do
          acc
        else
          Map.put(acc, run_id, active_entry)
        end
      end)

    {:reply, :ok,
     %{
       state
       | adapters: adapters,
         health: health,
         active_runs: active_runs,
         circuit_breakers: circuit_breakers
     }}
  end

  def handle_call(:status, _from, state) do
    status = %{
      adapters: Map.keys(state.adapters),
      health: state.health,
      active_runs:
        Map.new(state.active_runs, fn {run_id, active_entry} ->
          {run_id, active_entry.adapter_id}
        end),
      policy: state.policy,
      cooldown_ms: state.cooldown_ms,
      sticky_sessions: state.sticky_sessions,
      circuit_breakers:
        Map.new(state.circuit_breakers, fn {id, cb} -> {id, CircuitBreaker.to_map(cb)} end)
    }

    {:reply, status, state}
  end

  def handle_call({:execute, run, session, opts}, from, state) do
    router = self()

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        execute_routed(router, run, session, opts)
      end)

    pending_tasks = Map.put(state.pending_tasks, task.ref, from)
    {:noreply, %{state | pending_tasks: pending_tasks}}
  end

  def handle_call({:prepare_execution, run_id, session_id, routing_opts}, _from, state) do
    policy = resolve_policy(state.policy, routing_opts)
    required_capabilities = extract_required_capabilities(routing_opts)
    sticky_session_id = Keyword.get(routing_opts, :sticky_session_id)

    # Check stickiness before building candidates
    sticky_adapter = resolve_sticky_adapter(state, sticky_session_id)

    candidates = build_candidates(state, policy, required_capabilities)
    attempt_limit = RoutingPolicy.attempt_limit(policy, length(candidates))

    # If we have a sticky adapter and it's in the candidate list, move it to front
    candidates = apply_stickiness(candidates, sticky_adapter)

    plan = %{
      run_id: run_id,
      session_id: session_id,
      sticky_session_id: sticky_session_id,
      candidates: candidates,
      candidate_ids: Enum.map(candidates, & &1.id),
      attempt_limit: attempt_limit
    }

    {:reply, {:ok, plan}, state}
  end

  def handle_call({:bind_run, run_id, adapter_id}, _from, state) do
    case Map.get(state.adapters, adapter_id) do
      nil ->
        {:reply, {:error, Error.new(:provider_unavailable, "Unknown adapter: #{adapter_id}")},
         state}

      adapter_entry ->
        active_runs =
          Map.put(state.active_runs, run_id, %{
            adapter_id: adapter_id,
            adapter: adapter_entry.adapter
          })

        {:reply, :ok, %{state | active_runs: active_runs}}
    end
  end

  def handle_call(
        {:record_attempt_result, run_id, adapter_id, result, sticky_session_id},
        _from,
        state
      ) do
    health = update_health(state.health, adapter_id, result)
    active_runs = Map.delete(state.active_runs, run_id)

    circuit_breakers = update_circuit_breaker(state.circuit_breakers, adapter_id, result)

    # Update stickiness on success
    sticky_sessions =
      update_stickiness(state.sticky_sessions, sticky_session_id, adapter_id, result)

    {:reply, :ok,
     %{
       state
       | health: health,
         active_runs: active_runs,
         circuit_breakers: circuit_breakers,
         sticky_sessions: sticky_sessions
     }}
  end

  # Keep backward-compatible 4-element tuple
  def handle_call({:record_attempt_result, run_id, adapter_id, result}, _from, state) do
    health = update_health(state.health, adapter_id, result)
    active_runs = Map.delete(state.active_runs, run_id)
    circuit_breakers = update_circuit_breaker(state.circuit_breakers, adapter_id, result)

    {:reply, :ok,
     %{state | health: health, active_runs: active_runs, circuit_breakers: circuit_breakers}}
  end

  def handle_call({:cancel, run_id}, _from, state) do
    case Map.get(state.active_runs, run_id) do
      nil ->
        {:reply, {:error, Error.new(:run_not_found, "No active routed run found: #{run_id}")},
         state}

      %{adapter: adapter} ->
        {:reply, ProviderAdapter.cancel(adapter, run_id), state}
    end
  end

  @impl GenServer
  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    case Map.pop(state.pending_tasks, task_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {from, pending_tasks} ->
        Process.demonitor(task_ref, [:flush])
        GenServer.reply(from, result)
        {:noreply, %{state | pending_tasks: pending_tasks}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, task_ref, :process, _pid, reason}, state) do
    case Map.pop(state.pending_tasks, task_ref) do
      {nil, _pending} ->
        {:noreply, state}

      {from, pending_tasks} ->
        Process.demonitor(task_ref, [:flush])
        error = Error.new(:internal_error, "Router task crashed: #{inspect(reason)}")
        GenServer.reply(from, {:error, error})
        {:noreply, %{state | pending_tasks: pending_tasks}}
    end
  end

  # ============================================================================
  # Routing Execution
  # ============================================================================

  defp execute_routed(router, run, session, opts) do
    routing_opts = extract_routing_opts(opts)
    adapter_opts = Keyword.delete(opts, :routing)
    session_id = session.id

    with {:ok, plan} <-
           GenServer.call(router, {:prepare_execution, run.id, session_id, routing_opts}),
         {:ok, result} <- execute_plan(router, run, session, adapter_opts, plan, 1, nil) do
      {:ok, result}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, error} ->
        {:error, normalize_error(error)}
    end
  end

  defp execute_plan(
         _router,
         _run,
         _session,
         _opts,
         %{attempt_limit: 0},
         _attempt,
         _failover_context
       ) do
    {:error, Error.new(:provider_unavailable, "No eligible providers for this run")}
  end

  defp execute_plan(router, run, session, opts, plan, attempt, failover_context) do
    if attempt > plan.attempt_limit do
      {:error, Error.new(:provider_unavailable, "No more providers available for failover")}
    else
      candidate = Enum.at(plan.candidates, attempt - 1)

      case GenServer.call(router, {:bind_run, run.id, candidate.id}) do
        :ok ->
          attempt_opts =
            wrap_event_callback(
              opts,
              candidate.id,
              attempt,
              plan.candidate_ids,
              failover_context
            )

          emit_routing_telemetry_start(run, session, candidate.id, attempt, plan.candidate_ids)
          start_time = System.monotonic_time()

          result = execute_candidate(candidate, run, session, attempt_opts)

          emit_routing_telemetry_result(
            run,
            session,
            candidate.id,
            attempt,
            plan.candidate_ids,
            result,
            start_time
          )

          :ok =
            GenServer.call(
              router,
              {:record_attempt_result, run.id, candidate.id, result, plan.sticky_session_id}
            )

          attempt_context =
            build_attempt_context(
              router,
              run,
              session,
              opts,
              plan,
              attempt,
              candidate,
              failover_context
            )

          handle_attempt_result(attempt_context, result)

        {:error, %Error{} = error} ->
          {:error, error}
      end
    end
  end

  defp handle_attempt_result(
         %{
           plan: plan,
           attempt: attempt,
           candidate: candidate,
           failover_context: failover_context
         },
         {:ok, result}
       ) do
    routing_metadata =
      %{
        routed_provider: candidate.id,
        routing_attempt: attempt,
        routing_candidates: plan.candidate_ids
      }
      |> maybe_put_failover_context(failover_context)

    {:ok, Map.put(result, :routing, routing_metadata)}
  end

  defp handle_attempt_result(
         %{
           router: router,
           run: run,
           session: session,
           opts: opts,
           plan: plan,
           attempt: attempt,
           candidate: candidate
         },
         {:error, error}
       ) do
    normalized_error = normalize_error(error)

    if Error.retryable?(normalized_error) and attempt < plan.attempt_limit do
      failover_context = %{from: candidate.id, reason: normalized_error.code}
      execute_plan(router, run, session, opts, plan, attempt + 1, failover_context)
    else
      {:error, normalized_error}
    end
  end

  defp build_attempt_context(
         router,
         run,
         session,
         opts,
         plan,
         attempt,
         candidate,
         failover_context
       ) do
    %{
      router: router,
      run: run,
      session: session,
      opts: opts,
      plan: plan,
      attempt: attempt,
      candidate: candidate,
      failover_context: failover_context
    }
  end

  # ============================================================================
  # Candidate Building
  # ============================================================================

  defp build_candidates(state, policy, required_capabilities) do
    descriptors =
      state.adapters
      |> Map.values()
      |> Enum.map(fn adapter_entry ->
        %{
          id: adapter_entry.id,
          adapter: adapter_entry.adapter,
          capabilities: fetch_adapter_capabilities(adapter_entry.adapter),
          opts: adapter_entry.opts
        }
      end)

    descriptors
    |> Enum.filter(fn descriptor ->
      CapabilityMatcher.matches_all?(descriptor.capabilities, required_capabilities)
    end)
    |> then(&RoutingPolicy.order_candidates(policy, &1, health: state.health))
    |> Enum.filter(fn descriptor ->
      adapter_allowed?(state, descriptor.id)
    end)
  end

  defp adapter_allowed?(state, adapter_id) do
    cooldown_ok = healthy?(state.health, adapter_id, state.cooldown_ms)

    cb_ok =
      case Map.get(state.circuit_breakers, adapter_id) do
        nil -> true
        cb -> CircuitBreaker.allowed?(cb)
      end

    cooldown_ok and cb_ok
  end

  # ============================================================================
  # Session Stickiness
  # ============================================================================

  defp resolve_sticky_adapter(_state, nil), do: nil

  defp resolve_sticky_adapter(state, sticky_session_id) when is_binary(sticky_session_id) do
    case Map.get(state.sticky_sessions, sticky_session_id) do
      %{adapter_id: adapter_id, expires_at_ms: expires_at} ->
        if System.monotonic_time(:millisecond) < expires_at do
          adapter_id
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp apply_stickiness(candidates, nil), do: candidates

  defp apply_stickiness(candidates, sticky_adapter_id) do
    case Enum.split_with(candidates, fn c -> c.id == sticky_adapter_id end) do
      {[sticky], rest} -> [sticky | rest]
      _ -> candidates
    end
  end

  defp update_stickiness(sticky_sessions, nil, _adapter_id, _result), do: sticky_sessions

  defp update_stickiness(sticky_sessions, sticky_session_id, adapter_id, {:ok, _result}) do
    # Use a hardcoded TTL that matches the router's configured TTL
    # The TTL is stored by the caller as part of the plan
    ttl_ms = Config.get(:sticky_session_ttl_ms)

    Map.put(sticky_sessions, sticky_session_id, %{
      adapter_id: adapter_id,
      expires_at_ms: System.monotonic_time(:millisecond) + ttl_ms
    })
  end

  defp update_stickiness(sticky_sessions, _sticky_session_id, _adapter_id, _error),
    do: sticky_sessions

  # ============================================================================
  # Circuit Breaker
  # ============================================================================

  defp update_circuit_breaker(circuit_breakers, adapter_id, result) do
    case Map.get(circuit_breakers, adapter_id) do
      nil ->
        circuit_breakers

      cb ->
        updated_cb =
          case result do
            {:ok, _} -> CircuitBreaker.record_success(cb)
            {:error, _} -> CircuitBreaker.record_failure(cb)
          end

        Map.put(circuit_breakers, adapter_id, updated_cb)
    end
  end

  # ============================================================================
  # Routing Telemetry
  # ============================================================================

  defp emit_routing_telemetry_start(run, session, adapter_id, attempt, candidate_ids) do
    if telemetry_enabled?() do
      :telemetry.execute(
        [:agent_session_manager, :router, :attempt, :start],
        %{system_time: System.system_time()},
        %{
          session_id: session.id,
          run_id: run.id,
          adapter_id: adapter_id,
          attempt: attempt,
          candidate_ids: candidate_ids
        }
      )
    end

    :ok
  end

  defp emit_routing_telemetry_result(
         run,
         session,
         adapter_id,
         attempt,
         candidate_ids,
         result,
         start_time
       ) do
    if telemetry_enabled?() do
      duration = System.monotonic_time() - start_time

      case result do
        {:ok, _} ->
          :telemetry.execute(
            [:agent_session_manager, :router, :attempt, :stop],
            %{duration: duration, system_time: System.system_time()},
            %{
              session_id: session.id,
              run_id: run.id,
              adapter_id: adapter_id,
              attempt: attempt,
              candidate_ids: candidate_ids
            }
          )

        {:error, error} ->
          :telemetry.execute(
            [:agent_session_manager, :router, :attempt, :exception],
            %{duration: duration, system_time: System.system_time()},
            %{
              session_id: session.id,
              run_id: run.id,
              adapter_id: adapter_id,
              attempt: attempt,
              candidate_ids: candidate_ids,
              error_code: Map.get(error, :code)
            }
          )
      end
    end

    :ok
  end

  defp telemetry_enabled? do
    AgentSessionManager.Config.get(:telemetry_enabled)
  end

  # ============================================================================
  # Policy Resolution
  # ============================================================================

  defp resolve_policy(base_policy, routing_opts) do
    policy_opts =
      Map.merge(
        Map.new(
          Keyword.take(routing_opts, [:prefer, :exclude, :max_attempts, :weights, :strategy])
        ),
        normalize_policy_override(Keyword.get(routing_opts, :policy, %{}))
      )

    RoutingPolicy.merge(base_policy, policy_opts)
  end

  defp normalize_policy_override(policy_override) when is_list(policy_override),
    do: Map.new(policy_override)

  defp normalize_policy_override(policy_override) when is_map(policy_override),
    do: policy_override

  defp normalize_policy_override(_), do: %{}

  defp extract_required_capabilities(routing_opts) do
    routing_opts
    |> Keyword.get(:required_capabilities, [])
    |> List.wrap()
  end

  defp extract_routing_opts(opts) do
    opts
    |> Keyword.get(:routing, [])
    |> normalize_routing_opts()
  end

  defp normalize_routing_opts(opts) when is_list(opts), do: opts
  defp normalize_routing_opts(opts) when is_map(opts), do: Map.to_list(opts)
  defp normalize_routing_opts(_), do: []

  # ============================================================================
  # Event Callback Wrapping
  # ============================================================================

  defp wrap_event_callback(opts, routed_provider, attempt, candidate_ids, failover_context) do
    case Keyword.get(opts, :event_callback) do
      nil ->
        opts

      callback when is_function(callback, 1) ->
        wrapped_callback = fn event ->
          callback.(
            attach_routing_event_metadata(
              event,
              routed_provider,
              attempt,
              candidate_ids,
              failover_context
            )
          )
        end

        Keyword.put(opts, :event_callback, wrapped_callback)
    end
  end

  defp attach_routing_event_metadata(
         event,
         routed_provider,
         attempt,
         candidate_ids,
         failover_context
       ) do
    data = ensure_map(Map.get(event, :data))

    routing_metadata =
      %{
        routed_provider: routed_provider,
        routing_attempt: attempt,
        routing_candidates: candidate_ids
      }
      |> maybe_put_failover_context(failover_context)

    Map.put(event, :data, Map.merge(data, routing_metadata))
  end

  defp maybe_put_failover_context(metadata, nil), do: metadata

  defp maybe_put_failover_context(metadata, %{from: from, reason: reason}) do
    metadata
    |> Map.put(:failover_from, from)
    |> Map.put(:failover_reason, reason)
  end

  # ============================================================================
  # Health
  # ============================================================================

  defp normalize_adapter_id(id) when is_binary(id) and id != "", do: id
  defp normalize_adapter_id(_invalid), do: nil

  defp normalize_cooldown(value) when is_integer(value) and value >= 0, do: value
  defp normalize_cooldown(_invalid), do: Config.get(:circuit_breaker_cooldown_ms)

  defp normalize_ttl(value) when is_integer(value) and value >= 0, do: value
  defp normalize_ttl(_invalid), do: Config.get(:sticky_session_ttl_ms)

  defp normalize_cb_opts(opts, cooldown_ms) when is_list(opts) do
    Keyword.put_new(opts, :cooldown_ms, cooldown_ms)
  end

  defp normalize_cb_opts(_invalid, cooldown_ms), do: [cooldown_ms: cooldown_ms]

  defp healthy?(health_map, adapter_id, cooldown_ms) do
    case Map.get(health_map, adapter_id, default_health()) do
      %{failure_count: 0} ->
        true

      %{last_failure_at: nil} ->
        true

      %{last_failure_at: last_failure_at} ->
        DateTime.diff(DateTime.utc_now(), last_failure_at, :millisecond) >= cooldown_ms
    end
  end

  defp update_health(health_map, adapter_id, {:ok, _result}) do
    Map.put(health_map, adapter_id, default_health())
  end

  defp update_health(health_map, adapter_id, {:error, _error}) do
    previous = Map.get(health_map, adapter_id, default_health())

    updated = %{
      failure_count: previous.failure_count + 1,
      last_failure_at: DateTime.utc_now()
    }

    Map.put(health_map, adapter_id, updated)
  end

  defp update_health(health_map, _adapter_id, _result), do: health_map

  defp default_health do
    %{failure_count: 0, last_failure_at: nil}
  end

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_), do: %{}

  defp normalize_error(%Error{} = error), do: error

  defp normalize_error(%{code: code, message: message})
       when is_atom(code) and is_binary(message) do
    Error.new(code, message)
  end

  defp normalize_error(error) do
    Error.new(:provider_error, inspect(error))
  end

  defp execute_candidate(candidate, run, session, opts) do
    ProviderAdapter.execute(candidate.adapter, run, session, opts)
  rescue
    exception ->
      {:error, Error.wrap(:provider_error, exception)}
  catch
    :exit, reason ->
      {:error,
       Error.new(
         :provider_unavailable,
         "Provider adapter #{candidate.id} is unavailable: #{inspect(reason)}"
       )}
  end

  defp fetch_adapter_capabilities(adapter) do
    case ProviderAdapter.capabilities(adapter) do
      {:ok, returned_capabilities} when is_list(returned_capabilities) ->
        returned_capabilities

      _ ->
        []
    end
  rescue
    _exception ->
      []
  catch
    :exit, _reason ->
      []
  end
end
