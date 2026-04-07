defmodule ASM.Extensions.Routing.Router do
  @moduledoc """
  Extension-owned routing process for provider selection and failover.
  """

  use GenServer

  alias ASM.{Error, Provider}
  alias ASM.Extensions.Routing.HealthTracker
  alias ASM.Extensions.Routing.Strategy
  alias ASM.Extensions.Routing.Strategy.RoundRobin

  @default_priority 100
  @default_weight 1
  @default_call_timeout_ms 5_000

  @typedoc "Unique provider candidate identifier used by this router instance."
  @type provider_id :: HealthTracker.provider_id()

  @typedoc "Provider selection result returned by `select_provider/2`."
  @type selection :: %{
          id: provider_id(),
          provider: atom(),
          provider_opts: keyword()
        }

  @typedoc "Provider health information for routing decisions."
  @type health_status :: HealthTracker.health_status()

  @typep candidate :: %{
           required(:id) => provider_id(),
           required(:provider) => atom(),
           required(:provider_opts) => keyword(),
           required(:priority) => integer(),
           required(:weight) => pos_integer(),
           required(:position) => non_neg_integer()
         }

  @typep strategy_module :: module()
  @typep clock_fun :: (-> integer())

  @type t :: %__MODULE__{
          candidates: [candidate()],
          strategy: strategy_module(),
          strategy_state: Strategy.state(),
          health_tracker: HealthTracker.t(),
          clock: clock_fun()
        }

  @enforce_keys [:candidates, :strategy, :strategy_state, :health_tracker, :clock]
  defstruct [:candidates, :strategy, :strategy_state, :health_tracker, :clock]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec select_provider(pid(), keyword()) :: {:ok, selection()} | {:error, Error.t()}
  def select_provider(router, opts \\ []) when is_list(opts) do
    timeout = Keyword.get(opts, :timeout, @default_call_timeout_ms)
    strategy_opts = Keyword.delete(opts, :timeout)
    safe_call(router, {:select_provider, strategy_opts}, timeout, "select_provider/2 failed")
  end

  @spec report_success(pid(), selection() | provider_id()) :: :ok | {:error, Error.t()}
  def report_success(router, provider_ref) do
    safe_call(
      router,
      {:report_success, provider_ref},
      @default_call_timeout_ms,
      "report_success/2 failed"
    )
  end

  @spec report_failure(pid(), selection() | provider_id(), term()) :: :ok | {:error, Error.t()}
  def report_failure(router, provider_ref, reason) do
    safe_call(
      router,
      {:report_failure, provider_ref, reason},
      @default_call_timeout_ms,
      "report_failure/3 failed"
    )
  end

  @spec provider_health(pid(), provider_id()) :: {:ok, health_status()} | {:error, Error.t()}
  def provider_health(router, provider_id) do
    safe_call(
      router,
      {:provider_health, provider_id},
      @default_call_timeout_ms,
      "provider_health/2 failed"
    )
  end

  @spec health_snapshot(pid()) :: {:ok, %{provider_id() => health_status()}} | {:error, Error.t()}
  def health_snapshot(router) do
    safe_call(router, :health_snapshot, @default_call_timeout_ms, "health_snapshot/1 failed")
  end

  @impl true
  def init(opts) do
    with {:ok, candidates} <- build_candidates(Keyword.get(opts, :providers, [])),
         {:ok, strategy} <- resolve_strategy(Keyword.get(opts, :strategy, RoundRobin)),
         {:ok, strategy_state} <- strategy.init(Keyword.get(opts, :strategy_opts, [])),
         {:ok, health_tracker} <- init_health_tracker(candidates, opts),
         {:ok, clock} <- resolve_clock(Keyword.get(opts, :clock, &default_clock_ms/0)) do
      {:ok,
       %__MODULE__{
         candidates: candidates,
         strategy: strategy,
         strategy_state: strategy_state,
         health_tracker: health_tracker,
         clock: clock
       }}
    else
      {:error, %Error{} = error} ->
        {:stop, error}
    end
  end

  @impl true
  def handle_call({:select_provider, strategy_opts}, _from, state) do
    now_ms = now_ms(state)
    refreshed = HealthTracker.refresh(state.health_tracker, now_ms)
    available_ids = MapSet.new(HealthTracker.available_provider_ids(refreshed, now_ms))
    available = Enum.filter(state.candidates, &MapSet.member?(available_ids, &1.id))

    case state.strategy.choose(available, state.strategy_state, strategy_opts) do
      {:ok, candidate, strategy_state} ->
        selection = %{
          id: candidate.id,
          provider: candidate.provider,
          provider_opts: candidate.provider_opts
        }

        {:reply, {:ok, selection},
         %{state | strategy_state: strategy_state, health_tracker: refreshed}}

      :none ->
        {:reply, {:error, at_capacity_error()}, %{state | health_tracker: refreshed}}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, %{state | health_tracker: refreshed}}

      other ->
        error =
          Error.new(
            :unknown,
            :runtime,
            "routing strategy returned invalid response",
            cause: other
          )

        {:reply, {:error, error}, %{state | health_tracker: refreshed}}
    end
  end

  def handle_call({:report_success, provider_ref}, _from, state) do
    now_ms = now_ms(state)
    refreshed = HealthTracker.refresh(state.health_tracker, now_ms)

    with {:ok, provider_id} <- provider_id_from_ref(provider_ref),
         {:ok, next_tracker} <- HealthTracker.mark_success(refreshed, provider_id, now_ms) do
      {:reply, :ok, %{state | health_tracker: next_tracker}}
    else
      {:error, %Error{} = error} ->
        {:reply, {:error, error}, %{state | health_tracker: refreshed}}
    end
  end

  def handle_call({:report_failure, provider_ref, reason}, _from, state) do
    now_ms = now_ms(state)
    refreshed = HealthTracker.refresh(state.health_tracker, now_ms)

    with {:ok, provider_id} <- provider_id_from_ref(provider_ref),
         {:ok, next_tracker} <- HealthTracker.mark_failure(refreshed, provider_id, reason, now_ms) do
      {:reply, :ok, %{state | health_tracker: next_tracker}}
    else
      {:error, %Error{} = error} ->
        {:reply, {:error, error}, %{state | health_tracker: refreshed}}
    end
  end

  def handle_call({:provider_health, provider_id}, _from, state) do
    now_ms = now_ms(state)
    refreshed = HealthTracker.refresh(state.health_tracker, now_ms)

    case HealthTracker.status(refreshed, provider_id, now_ms) do
      {:ok, status} ->
        {:reply, {:ok, status}, %{state | health_tracker: refreshed}}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, %{state | health_tracker: refreshed}}
    end
  end

  def handle_call(:health_snapshot, _from, state) do
    now_ms = now_ms(state)
    refreshed = HealthTracker.refresh(state.health_tracker, now_ms)
    snapshot = HealthTracker.snapshot(refreshed, now_ms)
    {:reply, {:ok, snapshot}, %{state | health_tracker: refreshed}}
  end

  defp safe_call(router, message, timeout, operation) do
    GenServer.call(router, message, timeout)
  catch
    :exit, reason ->
      {:error, Error.new(:unknown, :runtime, operation, cause: reason)}
  end

  defp build_candidates(raw_candidates) when is_list(raw_candidates) do
    raw_candidates
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, {[], MapSet.new()}}, fn {entry, position},
                                                       {:ok, {acc, seen_ids}} ->
      with {:ok, candidate} <- normalize_candidate(entry, position),
           :ok <- ensure_unique_id(seen_ids, candidate.id) do
        {:cont, {:ok, {[candidate | acc], MapSet.put(seen_ids, candidate.id)}}}
      else
        {:error, %Error{} = error} ->
          {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, {[], _seen_ids}} ->
        {:error, config_error("routing requires at least one provider candidate")}

      {:ok, {candidates, _seen_ids}} ->
        {:ok, Enum.reverse(candidates)}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp build_candidates(_other) do
    {:error, config_error(":providers must be a list")}
  end

  defp normalize_candidate(provider_name, position) when is_atom(provider_name) do
    normalize_candidate(%{provider: provider_name}, position)
  end

  defp normalize_candidate(%Provider{} = provider, position) do
    normalize_candidate(%{provider: provider}, position)
  end

  defp normalize_candidate(candidate, position) when is_list(candidate) do
    if Keyword.keyword?(candidate) do
      normalize_candidate(Map.new(candidate), position)
    else
      {:error, config_error("provider candidate keyword list is invalid")}
    end
  end

  defp normalize_candidate(candidate, position) when is_map(candidate) and is_integer(position) do
    provider_input = Map.get(candidate, :provider)
    provider_opts = Map.get(candidate, :provider_opts, [])
    priority = Map.get(candidate, :priority, @default_priority)
    weight = Map.get(candidate, :weight, @default_weight)

    with {:ok, provider} <- Provider.resolve(provider_input),
         :ok <- validate_provider_opts(provider_opts),
         :ok <- validate_priority(priority),
         :ok <- validate_weight(weight) do
      provider_id = Map.get(candidate, :id, provider.name)

      if is_nil(provider_id) do
        {:error, config_error("provider candidate id cannot be nil")}
      else
        {:ok,
         %{
           id: provider_id,
           provider: provider.name,
           provider_opts: provider_opts,
           priority: priority,
           weight: weight,
           position: position
         }}
      end
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp normalize_candidate(_candidate, _position) do
    {:error,
     config_error("provider candidate must be an atom, map, keyword list, or %ASM.Provider{}")}
  end

  defp resolve_strategy(strategy) when is_atom(strategy) do
    cond do
      not Code.ensure_loaded?(strategy) ->
        {:error, config_error("routing strategy module not available: #{inspect(strategy)}")}

      not function_exported?(strategy, :choose, 3) ->
        {:error, config_error("routing strategy must implement choose/3: #{inspect(strategy)}")}

      not function_exported?(strategy, :init, 1) ->
        {:error, config_error("routing strategy must implement init/1: #{inspect(strategy)}")}

      true ->
        {:ok, strategy}
    end
  end

  defp resolve_strategy(other) do
    {:error, config_error("invalid routing strategy: #{inspect(other)}")}
  end

  defp init_health_tracker(candidates, opts) do
    provider_ids = Enum.map(candidates, & &1.id)
    health_opts = [failure_cooldown_ms: Keyword.get(opts, :failure_cooldown_ms, 30_000)]
    HealthTracker.new(provider_ids, health_opts)
  end

  defp resolve_clock(clock) when is_function(clock, 0), do: {:ok, clock}
  defp resolve_clock(_other), do: {:error, config_error(":clock must be a zero-arity function")}

  defp validate_provider_opts(provider_opts) when is_list(provider_opts), do: :ok

  defp validate_provider_opts(_other),
    do: {:error, config_error(":provider_opts must be a keyword list")}

  defp validate_priority(priority) when is_integer(priority), do: :ok
  defp validate_priority(_other), do: {:error, config_error(":priority must be an integer")}

  defp validate_weight(weight) when is_integer(weight) and weight > 0, do: :ok
  defp validate_weight(_other), do: {:error, config_error(":weight must be a positive integer")}

  defp ensure_unique_id(seen_ids, provider_id) do
    if MapSet.member?(seen_ids, provider_id) do
      {:error,
       config_error(
         "duplicate routing provider candidate id: #{inspect(provider_id)} (set explicit :id values)"
       )}
    else
      :ok
    end
  end

  defp provider_id_from_ref(%{id: provider_id}) when not is_nil(provider_id),
    do: {:ok, provider_id}

  defp provider_id_from_ref(provider_id) when not is_nil(provider_id), do: {:ok, provider_id}

  defp provider_id_from_ref(_other),
    do: {:error, config_error("provider reference must include :id")}

  defp now_ms(state) do
    case state.clock.() do
      value when is_integer(value) ->
        value

      _other ->
        default_clock_ms()
    end
  end

  defp default_clock_ms, do: System.monotonic_time(:millisecond)

  defp at_capacity_error do
    Error.new(:at_capacity, :runtime, "no healthy providers available for routing")
  end

  defp config_error(message) do
    Error.new(:config_invalid, :config, message)
  end
end
