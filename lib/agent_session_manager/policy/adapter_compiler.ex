defmodule AgentSessionManager.Policy.AdapterCompiler do
  @moduledoc """
  Compiles an effective policy into adapter-specific options.

  Provider-side enforcement is best-effort: when a provider supports
  native tool restrictions or output limits, the compiler maps policy
  constraints into the appropriate `adapter_opts`.

  When a provider does not support a constraint natively, the constraint
  is left to the reactive enforcement path (event callback + cancel).

  ## Supported Provider Mappings

  | Constraint         | Claude              | Codex               | Amp                 |
  |--------------------|---------------------|---------------------|---------------------|
  | Tool allow/deny    | `allowed_tools`     | `allowed_tools`     | `allowed_tools`     |
  | Max output tokens  | `max_tokens`        | `max_tokens`        | `max_tokens`        |

  Other constraints (token budget, duration, cost) are enforced reactively.
  """

  alias AgentSessionManager.Policy.Policy

  @doc """
  Compiles a policy into adapter options for provider-side enforcement.

  Returns a keyword list of adapter options to merge into `adapter_opts`.
  """
  @spec compile(Policy.t(), String.t()) :: keyword()
  def compile(%Policy{} = policy, provider_name) when is_binary(provider_name) do
    []
    |> compile_tool_rules(policy)
    |> compile_output_limits(policy, provider_name)
  end

  def compile(_policy, _provider_name), do: []

  # ------------------------------------------------------------------
  # Tool Rules
  # ------------------------------------------------------------------

  defp compile_tool_rules(opts, %Policy{tool_rules: rules}) when rules == [], do: opts

  defp compile_tool_rules(opts, %Policy{tool_rules: rules}) do
    # Extract effective allowed tools from rules
    # If there are :allow rules, use their intersection
    # If there are only :deny rules, we pass the deny list
    allow_lists =
      rules
      |> Enum.filter(fn {type, _} -> type == :allow end)
      |> Enum.map(fn {:allow, tools} -> MapSet.new(tools) end)

    deny_lists =
      rules
      |> Enum.filter(fn {type, _} -> type == :deny end)
      |> Enum.map(fn {:deny, tools} -> tools end)
      |> List.flatten()
      |> Enum.uniq()

    cond do
      allow_lists != [] ->
        # Intersect all allow lists, then subtract deny lists
        effective =
          allow_lists
          |> Enum.reduce(fn set, acc -> MapSet.intersection(set, acc) end)
          |> MapSet.difference(MapSet.new(deny_lists))
          |> MapSet.to_list()

        Keyword.put(opts, :allowed_tools, effective)

      deny_lists != [] ->
        Keyword.put(opts, :denied_tools, deny_lists)

      true ->
        opts
    end
  end

  # ------------------------------------------------------------------
  # Output Limits
  # ------------------------------------------------------------------

  defp compile_output_limits(opts, %Policy{limits: limits}, _provider_name) do
    case List.keyfind(limits, :max_total_tokens, 0) do
      {:max_total_tokens, tokens} when is_integer(tokens) and tokens > 0 ->
        # Use a fraction of the total budget as max_tokens hint to the provider
        # This is best-effort; the exact mapping depends on the provider
        Keyword.put_new(opts, :max_tokens, tokens)

      _ ->
        opts
    end
  end
end
