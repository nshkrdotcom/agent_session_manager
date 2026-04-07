defmodule ASM.Cost do
  @moduledoc """
  Cost helpers for token usage projection and accumulation.
  """

  alias ASM.Control
  alias ASM.Cost.Models

  @type usage :: map()

  @type totals :: %{
          required(:input_tokens) => non_neg_integer(),
          required(:output_tokens) => non_neg_integer(),
          required(:cost_usd) => float()
        }

  @spec from_usage(atom(), String.t() | nil, usage()) :: Control.CostUpdate.t()
  def from_usage(provider, model, usage) when is_atom(provider) and is_map(usage) do
    rates = Models.lookup(provider, model)
    input_tokens = int_value(usage, :input_tokens)
    output_tokens = int_value(usage, :output_tokens)

    %Control.CostUpdate{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      cost_usd: input_tokens * rates.input_rate + output_tokens * rates.output_rate
    }
  end

  @spec accumulate(totals(), Control.CostUpdate.t()) :: totals()
  def accumulate(current, %Control.CostUpdate{} = update) when is_map(current) do
    %{
      input_tokens: int_value(current, :input_tokens) + update.input_tokens,
      output_tokens: int_value(current, :output_tokens) + update.output_tokens,
      cost_usd: float_value(current, :cost_usd) + update.cost_usd
    }
  end

  defp int_value(map, key) when is_map(map) do
    map
    |> Map.get(key, Map.get(map, Atom.to_string(key), 0))
    |> case do
      value when is_integer(value) and value >= 0 -> value
      value when is_float(value) and value >= 0 -> trunc(value)
      _ -> 0
    end
  end

  defp float_value(map, key) when is_map(map) do
    map
    |> Map.get(key, Map.get(map, Atom.to_string(key), 0.0))
    |> case do
      value when is_float(value) -> value
      value when is_integer(value) -> value * 1.0
      _ -> 0.0
    end
  end
end
