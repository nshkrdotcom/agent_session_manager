defmodule AgentSessionManager.Policy.Policy do
  @moduledoc """
  Declarative policy definition for runtime enforcement.
  """

  alias AgentSessionManager.Core.Error

  @type limit ::
          {:max_total_tokens, non_neg_integer()}
          | {:max_duration_ms, non_neg_integer()}
          | {:max_tool_calls, non_neg_integer()}
          | {:max_cost_usd, float()}

  @type tool_rule :: {:allow, [String.t()]} | {:deny, [String.t()]}

  @type on_violation :: :cancel | :warn

  @type t :: %__MODULE__{
          name: String.t(),
          limits: [limit()],
          tool_rules: [tool_rule()],
          on_violation: on_violation(),
          metadata: map()
        }

  @enforce_keys [:name]
  defstruct name: "",
            limits: [],
            tool_rules: [],
            on_violation: :cancel,
            metadata: %{}

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs \\ [])

  def new(attrs) when is_list(attrs) do
    attrs
    |> Map.new()
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    with {:ok, name} <- validate_name(Map.get(attrs, :name, "default")),
         {:ok, limits} <- validate_limits(Map.get(attrs, :limits, [])),
         {:ok, tool_rules} <- validate_tool_rules(Map.get(attrs, :tool_rules, [])),
         {:ok, on_violation} <- validate_on_violation(Map.get(attrs, :on_violation, :cancel)),
         {:ok, metadata} <- validate_metadata(Map.get(attrs, :metadata, %{})) do
      {:ok,
       %__MODULE__{
         name: name,
         limits: limits,
         tool_rules: tool_rules,
         on_violation: on_violation,
         metadata: metadata
       }}
    end
  end

  def new(_invalid) do
    {:error, Error.new(:validation_error, "Policy must be a keyword list or map")}
  end

  @spec merge(t(), keyword() | map()) :: t()
  def merge(%__MODULE__{} = base, overrides) when is_list(overrides) do
    merge(base, Map.new(overrides))
  end

  def merge(%__MODULE__{} = base, overrides) when is_map(overrides) do
    merged_attrs = %{
      name: Map.get(overrides, :name, base.name),
      limits: Map.get(overrides, :limits, base.limits),
      tool_rules: Map.get(overrides, :tool_rules, base.tool_rules),
      on_violation: Map.get(overrides, :on_violation, base.on_violation),
      metadata: Map.get(overrides, :metadata, base.metadata)
    }

    case new(merged_attrs) do
      {:ok, merged_policy} -> merged_policy
      {:error, _} -> base
    end
  end

  defp validate_name(name) when is_binary(name) and name != "", do: {:ok, name}

  defp validate_name(_invalid),
    do: {:error, Error.new(:validation_error, "policy name is required")}

  defp validate_limits(limits) when is_list(limits) do
    limits
    |> Enum.reduce_while({:ok, []}, fn limit, {:ok, acc} ->
      case normalize_limit(limit) do
        {:ok, normalized_limit} -> {:cont, {:ok, acc ++ [normalized_limit]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_limits(_invalid),
    do: {:error, Error.new(:validation_error, "limits must be a list")}

  defp normalize_limit({:max_total_tokens, value})
       when is_integer(value) and value >= 0,
       do: {:ok, {:max_total_tokens, value}}

  defp normalize_limit({:max_duration_ms, value})
       when is_integer(value) and value >= 0,
       do: {:ok, {:max_duration_ms, value}}

  defp normalize_limit({:max_tool_calls, value})
       when is_integer(value) and value >= 0,
       do: {:ok, {:max_tool_calls, value}}

  defp normalize_limit({:max_cost_usd, value})
       when is_number(value) and value >= 0,
       do: {:ok, {:max_cost_usd, value * 1.0}}

  defp normalize_limit(_invalid) do
    {:error, Error.new(:validation_error, "invalid policy limit")}
  end

  defp validate_tool_rules(rules) when is_list(rules) do
    rules
    |> Enum.reduce_while({:ok, []}, fn rule, {:ok, acc} ->
      case normalize_tool_rule(rule) do
        {:ok, normalized_rule} -> {:cont, {:ok, acc ++ [normalized_rule]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp validate_tool_rules(_invalid) do
    {:error, Error.new(:validation_error, "tool_rules must be a list")}
  end

  defp normalize_tool_rule({:allow, tools}) do
    with {:ok, normalized_tools} <- normalize_tool_list(tools) do
      {:ok, {:allow, normalized_tools}}
    end
  end

  defp normalize_tool_rule({:deny, tools}) do
    with {:ok, normalized_tools} <- normalize_tool_list(tools) do
      {:ok, {:deny, normalized_tools}}
    end
  end

  defp normalize_tool_rule(_invalid) do
    {:error, Error.new(:validation_error, "invalid tool rule")}
  end

  defp normalize_tool_list(tools) when is_list(tools) do
    normalized =
      tools
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    {:ok, normalized}
  end

  defp normalize_tool_list(_invalid) do
    {:error, Error.new(:validation_error, "tool rule list must contain tool names")}
  end

  defp validate_on_violation(action) when action in [:cancel, :warn], do: {:ok, action}

  defp validate_on_violation(_invalid) do
    {:error, Error.new(:validation_error, "on_violation must be :cancel or :warn")}
  end

  defp validate_metadata(metadata) when is_map(metadata), do: {:ok, metadata}

  defp validate_metadata(_invalid),
    do: {:error, Error.new(:validation_error, "metadata must be a map")}
end
