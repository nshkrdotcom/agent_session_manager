defmodule AgentSessionManager.Routing.RoutingPolicy do
  @moduledoc """
  Routing policy for provider selection and failover attempts.
  """

  @enforce_keys []
  defstruct prefer: [],
            exclude: [],
            max_attempts: 3,
            weights: %{}

  @type candidate_id :: String.t()

  @type t :: %__MODULE__{
          prefer: [candidate_id()],
          exclude: [candidate_id()],
          max_attempts: pos_integer(),
          weights: map()
        }

  @type candidate :: %{required(:id) => candidate_id(), optional(any()) => any()}

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
      weights: normalize_weights(Map.get(opts, :weights, %{}))
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
      weights: Map.get(overrides, :weights, base.weights)
    }

    new(merged)
  end

  @spec order_candidates(t(), [candidate()]) :: [candidate()]
  def order_candidates(%__MODULE__{} = policy, candidates) when is_list(candidates) do
    filtered =
      Enum.filter(candidates, fn candidate ->
        candidate_id = Map.get(candidate, :id)
        is_binary(candidate_id) and candidate_id not in policy.exclude
      end)

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

  @spec attempt_limit(t(), non_neg_integer()) :: non_neg_integer()
  def attempt_limit(%__MODULE__{} = policy, candidate_count)
      when is_integer(candidate_count) and candidate_count >= 0 do
    limit = normalize_max_attempts(policy.max_attempts)
    min(limit, candidate_count)
  end

  defp normalize_id_list(value) when is_list(value) do
    value
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp normalize_id_list(_invalid), do: []

  defp normalize_max_attempts(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_attempts(_invalid), do: 3

  defp normalize_weights(value) when is_map(value), do: value
  defp normalize_weights(_invalid), do: %{}

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
