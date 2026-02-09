defmodule AgentSessionManager.Policy.Preflight do
  @moduledoc """
  Preflight policy checks that run before execution begins.

  Preflight evaluation catches impossible or invalid policy configurations
  early, returning `{:error, %Error{code: :policy_violation}}` with clear
  details instead of wasting provider resources.

  ## Checks

  - **Empty allow list**: if `{:allow, []}` is present, no tool can ever be
    used — the run is guaranteed to violate policy.
  - **Contradictory rules**: if a tool appears in both allow and deny lists.
  - **Zero-budget limits**: if `max_total_tokens: 0` or `max_tool_calls: 0`
    is set, the run cannot produce any useful output.
  """

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Policy.Policy

  @doc """
  Validates a policy before execution.

  Returns `:ok` if the policy is satisfiable, or
  `{:error, %Error{code: :policy_violation}}` with details if the policy
  is impossible to satisfy.
  """
  @spec check(Policy.t()) :: :ok | {:error, Error.t()}
  def check(%Policy{} = policy) do
    checks = [
      &check_empty_allow/1,
      &check_zero_budget/1,
      &check_contradictory_rules/1
    ]

    Enum.reduce_while(checks, :ok, fn check_fn, :ok ->
      case check_fn.(policy) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  def check(_policy), do: :ok

  # ------------------------------------------------------------------
  # Individual Checks
  # ------------------------------------------------------------------

  defp check_empty_allow(%Policy{tool_rules: rules}) do
    has_empty_allow =
      Enum.any?(rules, fn
        {:allow, tools} when is_list(tools) -> tools == []
        _ -> false
      end)

    if has_empty_allow do
      {:error,
       Error.new(
         :policy_violation,
         "Policy has an empty allow list: no tools can ever be used",
         details: %{check: :empty_allow_list}
       )}
    else
      :ok
    end
  end

  defp check_zero_budget(%Policy{limits: limits}) do
    zero_budget =
      Enum.find(limits, fn
        {:max_total_tokens, 0} -> true
        {:max_tool_calls, 0} -> true
        _ -> false
      end)

    case zero_budget do
      {kind, 0} ->
        {:error,
         Error.new(
           :policy_violation,
           "Policy has zero budget for #{kind}: run cannot produce useful output",
           details: %{check: :zero_budget, kind: kind}
         )}

      _ ->
        :ok
    end
  end

  defp check_contradictory_rules(%Policy{tool_rules: rules}) do
    allow_sets =
      rules
      |> Enum.filter(fn {type, _} -> type == :allow end)
      |> Enum.flat_map(fn {:allow, tools} -> tools end)
      |> MapSet.new()

    deny_sets =
      rules
      |> Enum.filter(fn {type, _} -> type == :deny end)
      |> Enum.flat_map(fn {:deny, tools} -> tools end)
      |> MapSet.new()

    contradictions = MapSet.intersection(allow_sets, deny_sets)

    if MapSet.size(contradictions) > 0 do
      {:error,
       Error.new(
         :policy_violation,
         "Policy has contradictory tool rules: #{Enum.join(contradictions, ", ")} appear in both allow and deny",
         details: %{check: :contradictory_rules, tools: MapSet.to_list(contradictions)}
       )}
    else
      :ok
    end
  end
end
