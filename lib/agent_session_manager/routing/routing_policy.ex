defmodule AgentSessionManager.Routing.RoutingPolicy do
  @moduledoc """
  Routing policy for provider selection and failover attempts.

  ## Strategies

  - `:prefer` (default) — order candidates by `prefer` list, then remaining.
    This preserves Phase 1 semantics.
  - `:weighted` — score each candidate using `weights` and health signals,
    then sort by descending score.  Ties are broken by `prefer` order.

  ## Weights

  When `strategy: :weighted`, the `weights` map assigns a static score to
  each adapter id.  Adapters not listed receive a default weight of `1.0`.
  Health penalties (failure count) are subtracted from the weight to produce
  the final score.
  """

  @enforce_keys []
  defstruct prefer: [],
            exclude: [],
            max_attempts: 3,
            weights: %{},
            strategy: :prefer

  @type candidate_id :: String.t()

  @type strategy :: :prefer | :weighted

  @type t :: %__MODULE__{
          prefer: [candidate_id()],
          exclude: [candidate_id()],
          max_attempts: pos_integer(),
          weights: %{optional(candidate_id()) => number()},
          strategy: strategy()
        }

  @type candidate :: %{required(:id) => candidate_id(), optional(any()) => any()}

  @type health_map :: %{optional(candidate_id()) => %{failure_count: non_neg_integer()}}

  @spec new(keyword() | map()) :: t()
  def new(opts \\ [])

  def new(opts) when is_list(opts) do
    opts
    |> Map.new()
    |> new()
  end

  def new(opts) when is_map(opts) do
    %__MODULE__{
      prefer: normalize_id_list(Map.get(opts, :prefer, [])),
      exclude: normalize_id_list(Map.get(opts, :exclude, [])),
      max_attempts: normalize_max_attempts(Map.get(opts, :max_attempts, 3)),
      weights: normalize_weights(Map.get(opts, :weights, %{})),
      strategy: normalize_strategy(Map.get(opts, :strategy, :prefer))
    }
  end

  @spec merge(t(), keyword() | map()) :: t()
  def merge(%__MODULE__{} = base, overrides) when is_list(overrides) do
    merge(base, Map.new(overrides))
  end

  def merge(%__MODULE__{} = base, overrides) when is_map(overrides) do
    merged = %{
      prefer: Map.get(overrides, :prefer, base.prefer),
      exclude: Map.get(overrides, :exclude, base.exclude),
      max_attempts: Map.get(overrides, :max_attempts, base.max_attempts),
      weights: Map.get(overrides, :weights, base.weights),
      strategy: Map.get(overrides, :strategy, base.strategy)
    }

    new(merged)
  end

  @doc """
  Orders candidates according to the policy strategy.

  - `:prefer` — apply prefer/exclude filters and reorder by `prefer` list.
  - `:weighted` — score candidates using `weights` and optional health data,
    break ties with `prefer` order, then return sorted.

  The `opts` keyword list may include:

  - `:health` — a map of `%{adapter_id => %{failure_count: n}}` used to
    penalize unhealthy adapters when `strategy: :weighted`.
  """
  @spec order_candidates(t(), [candidate()], keyword()) :: [candidate()]
  def order_candidates(policy, candidates, opts \\ [])

  def order_candidates(%__MODULE__{strategy: :prefer} = policy, candidates, _opts)
      when is_list(candidates) do
    order_candidates_prefer(policy, candidates)
  end

  def order_candidates(%__MODULE__{strategy: :weighted} = policy, candidates, opts)
      when is_list(candidates) do
    health = Keyword.get(opts, :health, %{})
    order_candidates_weighted(policy, candidates, health)
  end

  @spec attempt_limit(t(), non_neg_integer()) :: non_neg_integer()
  def attempt_limit(%__MODULE__{} = policy, candidate_count)
      when is_integer(candidate_count) and candidate_count >= 0 do
    limit = normalize_max_attempts(policy.max_attempts)
    min(limit, candidate_count)
  end

  @doc """
  Computes the weighted score for a single candidate.

  Score = `weight(candidate_id)` − `failure_count * penalty_per_failure`.
  The penalty per failure is `0.5` by default.
  """
  @spec score(t(), candidate_id(), health_map()) :: float()
  def score(%__MODULE__{} = policy, candidate_id, health) do
    base_weight = Map.get(policy.weights, candidate_id, 1.0) * 1.0
    failure_count = get_failure_count(health, candidate_id)
    penalty = failure_count * 0.5
    base_weight - penalty
  end

  # ------------------------------------------------------------------
  # Private
  # ------------------------------------------------------------------

  defp order_candidates_prefer(policy, candidates) do
    filtered = exclude_candidates(policy, candidates)

    {preferred, remaining} =
      Enum.reduce(policy.prefer, {[], filtered}, fn preferred_id,
                                                    {preferred_acc, remaining_acc} ->
        case pop_candidate_by_id(remaining_acc, preferred_id) do
          {nil, untouched} ->
            {preferred_acc, untouched}

          {candidate, rest} ->
            {preferred_acc ++ [candidate], rest}
        end
      end)

    preferred ++ remaining
  end

  defp order_candidates_weighted(policy, candidates, health) do
    filtered = exclude_candidates(policy, candidates)

    # Build a prefer-rank map for tie-breaking (lower is better)
    prefer_rank =
      policy.prefer
      |> Enum.with_index()
      |> Map.new()

    max_prefer = length(policy.prefer)

    filtered
    |> Enum.map(fn candidate ->
      candidate_score = score(policy, candidate.id, health)
      rank = Map.get(prefer_rank, candidate.id, max_prefer)
      {candidate, candidate_score, rank}
    end)
    |> Enum.sort_by(fn {_c, s, r} -> {-s, r} end)
    |> Enum.map(fn {candidate, _score, _rank} -> candidate end)
  end

  defp exclude_candidates(policy, candidates) do
    Enum.filter(candidates, fn candidate ->
      candidate_id = Map.get(candidate, :id)
      is_binary(candidate_id) and candidate_id not in policy.exclude
    end)
  end

  defp get_failure_count(health, candidate_id) do
    case Map.get(health, candidate_id) do
      %{failure_count: count} when is_integer(count) and count >= 0 -> count
      _ -> 0
    end
  end

  defp normalize_id_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp normalize_id_list(_invalid), do: []

  defp normalize_max_attempts(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_attempts(_invalid), do: 3

  defp normalize_weights(value) when is_map(value) do
    Map.new(value, fn {k, v} ->
      {to_string(k), normalize_weight_value(v)}
    end)
  end

  defp normalize_weights(_invalid), do: %{}

  defp normalize_weight_value(v) when is_number(v) and v >= 0, do: v * 1.0
  defp normalize_weight_value(_), do: 1.0

  defp normalize_strategy(:prefer), do: :prefer
  defp normalize_strategy(:weighted), do: :weighted
  defp normalize_strategy(_invalid), do: :prefer

  defp pop_candidate_by_id(candidates, id) do
    index = Enum.find_index(candidates, fn candidate -> Map.get(candidate, :id) == id end)

    case index do
      nil ->
        {nil, candidates}

      idx ->
        {candidate, rest} = List.pop_at(candidates, idx)
        {candidate, rest}
    end
  end
end
