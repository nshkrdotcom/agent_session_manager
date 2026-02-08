defmodule AgentSessionManager.Policy.Evaluator do
  @moduledoc """
  Pure policy checks for event-driven runtime enforcement.
  """

  alias AgentSessionManager.Policy.Policy

  @type runtime_state :: %{
          optional(:tool_calls) => non_neg_integer(),
          optional(:total_tokens) => non_neg_integer(),
          optional(:elapsed_ms) => non_neg_integer(),
          optional(:accumulated_cost_usd) => float(),
          optional(:cost_supported?) => boolean()
        }

  @type violation :: %{
          policy: String.t(),
          kind: atom(),
          action: Policy.on_violation(),
          details: map()
        }

  @spec evaluate(Policy.t(), runtime_state(), map(), keyword()) :: [violation()]
  def evaluate(policy, runtime_state, event, opts \\ [])

  def evaluate(%Policy{} = policy, runtime_state, event, opts)
      when is_map(runtime_state) and is_map(event) and is_list(opts) do
    tool_rule_violations = evaluate_tool_rules(policy, event)
    limit_violations = evaluate_limits(policy, runtime_state, opts)
    tool_rule_violations ++ limit_violations
  end

  def evaluate(_policy, _runtime_state, _event, _opts), do: []

  defp evaluate_tool_rules(%Policy{tool_rules: []}, _event), do: []

  defp evaluate_tool_rules(%Policy{} = policy, event) do
    case extract_tool_name(event) do
      tool_name when is_binary(tool_name) ->
        Enum.flat_map(policy.tool_rules, fn tool_rule ->
          evaluate_tool_rule(policy, tool_name, tool_rule)
        end)

      _ ->
        []
    end
  end

  defp evaluate_tool_rule(policy, tool_name, {:deny, denied_tools}) do
    if tool_name in denied_tools do
      [
        violation(policy, :tool_denied, %{
          tool_name: tool_name,
          rule: :deny,
          denied_tools: denied_tools
        })
      ]
    else
      []
    end
  end

  defp evaluate_tool_rule(policy, tool_name, {:allow, allowed_tools}) do
    if tool_name in allowed_tools do
      []
    else
      [
        violation(policy, :tool_denied, %{
          tool_name: tool_name,
          rule: :allow,
          allowed_tools: allowed_tools
        })
      ]
    end
  end

  defp evaluate_limits(%Policy{} = policy, runtime_state, _opts) do
    Enum.flat_map(policy.limits, fn
      {:max_total_tokens, limit} ->
        actual = Map.get(runtime_state, :total_tokens, 0)
        budget_violation(policy, :total_tokens, actual, limit)

      {:max_duration_ms, limit} ->
        actual = Map.get(runtime_state, :elapsed_ms, 0)
        budget_violation(policy, :duration_ms, actual, limit)

      {:max_tool_calls, limit} ->
        actual = Map.get(runtime_state, :tool_calls, 0)
        budget_violation(policy, :tool_calls, actual, limit)

      {:max_cost_usd, limit} ->
        if Map.get(runtime_state, :cost_supported?, false) do
          actual = Map.get(runtime_state, :accumulated_cost_usd, 0.0)
          budget_violation(policy, :cost_usd, actual, limit)
        else
          []
        end
    end)
  end

  defp budget_violation(policy, metric, actual, limit) when actual > limit do
    [
      violation(policy, :budget_exceeded, %{
        metric: metric,
        actual: actual,
        limit: limit
      })
    ]
  end

  defp budget_violation(_policy, _metric, _actual, _limit), do: []

  defp violation(%Policy{} = policy, kind, details) do
    %{
      policy: policy.name,
      kind: kind,
      action: policy.on_violation,
      details: details
    }
  end

  defp extract_tool_name(event) when is_map(event) do
    data = Map.get(event, :data, %{})
    Map.get(data, :tool_name) || Map.get(data, :name)
  end
end
