defmodule AgentSessionManager.Cost.CostCalculator do
  @moduledoc """
  Converts token usage counts into USD cost estimates using
  configurable per-model pricing tables.
  """

  alias AgentSessionManager.Core.Run
  alias AgentSessionManager.Models

  @type token_counts :: map()
  @type rate_entry :: map()
  @type pricing_table :: map()

  @spec calculate(token_counts(), String.t() | nil, String.t() | nil, pricing_table()) ::
          {:ok, float()} | {:error, :no_rates}
  def calculate(tokens, provider, model, pricing_table)
      when is_map(tokens) and is_binary(provider) and is_map(pricing_table) do
    with {:ok, rates} <- resolve_rates(provider, model, pricing_table) do
      input_tokens = token_value(tokens, :input_tokens)
      output_tokens = token_value(tokens, :output_tokens)
      cache_read_tokens = token_value(tokens, :cache_read_tokens)
      cache_creation_tokens = token_value(tokens, :cache_creation_tokens)

      input_rate = rates.input
      output_rate = rates.output
      cache_read_rate = Map.get(rates, :cache_read, input_rate)
      cache_creation_rate = Map.get(rates, :cache_creation, input_rate)

      cost =
        input_tokens * input_rate +
          output_tokens * output_rate +
          cache_read_tokens * cache_read_rate +
          cache_creation_tokens * cache_creation_rate

      {:ok, cost * 1.0}
    end
  end

  def calculate(_tokens, _provider, _model, _pricing_table), do: {:error, :no_rates}

  @spec resolve_rates(String.t() | nil, String.t() | nil, pricing_table()) ::
          {:ok, rate_entry()} | {:error, :no_rates}
  def resolve_rates(provider, model, pricing_table)
      when is_binary(provider) and is_map(pricing_table) do
    pricing_table = normalize_legacy_rates(pricing_table)

    case Map.get(pricing_table, provider) do
      nil -> {:error, :no_rates}
      provider_entry when is_map(provider_entry) -> resolve_model_rates(provider_entry, model)
    end
  end

  def resolve_rates(_provider, _model, _pricing_table), do: {:error, :no_rates}

  defp resolve_model_rates(provider_entry, model) when is_binary(model) do
    models = map_get(provider_entry, :models, %{})
    find_model_rates(models, model, provider_entry)
  end

  defp resolve_model_rates(provider_entry, _model), do: provider_default(provider_entry)

  defp find_model_rates(models, model, provider_entry) when is_map(models) do
    if Map.has_key?(models, model) do
      normalize_rate_entry(Map.get(models, model))
    else
      case longest_prefix_match(models, model) do
        {:ok, matched_rates} -> normalize_rate_entry(matched_rates)
        :error -> provider_default(provider_entry)
      end
    end
  end

  defp find_model_rates(_models, _model, provider_entry), do: provider_default(provider_entry)

  @spec calculate_run_cost(Run.t(), pricing_table()) :: {:ok, float()} | {:error, :no_rates}
  def calculate_run_cost(%Run{} = run, pricing_table) when is_map(pricing_table) do
    provider = run.provider
    model = map_get(run.provider_metadata || %{}, :model)
    token_usage = run.token_usage || %{}

    calculate(token_usage, provider, model, pricing_table)
  end

  def calculate_run_cost(_run, _pricing_table), do: {:error, :no_rates}

  @spec normalize_legacy_rates(map()) :: map()
  def normalize_legacy_rates(pricing_table) when is_map(pricing_table) do
    if structured_pricing_table?(pricing_table) do
      pricing_table
    else
      Map.new(pricing_table, &normalize_provider_rates/1)
    end
  end

  def normalize_legacy_rates(other), do: other

  @spec default_pricing_table() :: pricing_table()
  def default_pricing_table do
    Models.default_pricing_table()
  end

  defp provider_default(provider_entry) do
    provider_entry
    |> map_get(:default)
    |> normalize_rate_entry()
  end

  defp normalize_provider_rates({provider, rates}) do
    case normalize_flat_rates(rates) do
      {:ok, normalized} -> {provider, normalized}
      :error -> {provider, rates}
    end
  end

  defp normalize_rate_entry(%{} = rates) do
    with {:ok, input} <- to_float(map_get(rates, :input)),
         {:ok, output} <- to_float(map_get(rates, :output)) do
      normalized = %{input: input, output: output}

      normalized =
        normalized
        |> maybe_put_rate(:cache_read, map_get(rates, :cache_read))
        |> maybe_put_rate(:cache_creation, map_get(rates, :cache_creation))

      {:ok, normalized}
    else
      _ -> {:error, :no_rates}
    end
  end

  defp normalize_rate_entry(_), do: {:error, :no_rates}

  defp maybe_put_rate(map, _key, nil), do: map

  defp maybe_put_rate(map, key, value) do
    case to_float(value) do
      {:ok, value} -> Map.put(map, key, value)
      _ -> map
    end
  end

  defp longest_prefix_match(models, model) do
    models
    |> Enum.filter(fn
      {candidate, _rates} when is_binary(candidate) -> String.starts_with?(model, candidate)
      _ -> false
    end)
    |> Enum.max_by(fn {candidate, _rates} -> String.length(candidate) end, fn -> nil end)
    |> case do
      nil -> :error
      {_candidate, rates} -> {:ok, rates}
    end
  end

  defp token_value(tokens, key) do
    value = map_get(tokens, key, 0)

    cond do
      is_integer(value) and value >= 0 -> value
      is_float(value) and value >= 0 -> trunc(value)
      true -> 0
    end
  end

  defp structured_pricing_table?(pricing_table) do
    Enum.any?(pricing_table, fn {_provider, entry} ->
      is_map(entry) and (Map.has_key?(entry, :default) or Map.has_key?(entry, "default"))
    end)
  end

  defp normalize_flat_rates(%{} = rates) do
    with {:ok, input} <- to_float(map_get(rates, :input)),
         {:ok, output} <- to_float(map_get(rates, :output)) do
      {:ok, %{default: %{input: input, output: output}, models: %{}}}
    else
      _ -> :error
    end
  end

  defp normalize_flat_rates(_), do: :error

  defp to_float(value) when is_integer(value), do: {:ok, value * 1.0}
  defp to_float(value) when is_float(value), do: {:ok, value}
  defp to_float(_), do: :error

  defp map_get(map, key, default \\ nil)

  defp map_get(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp map_get(_map, _key, default), do: default
end
