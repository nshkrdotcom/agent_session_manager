defmodule ASM.Cost.Models do
  @moduledoc """
  Lightweight model pricing lookup table for provider cost estimation.
  """

  @type rates :: %{required(:input_rate) => float(), required(:output_rate) => float()}

  @defaults %{
    claude: %{input_rate: 0.000003, output_rate: 0.000015},
    gemini: %{input_rate: 0.0000015, output_rate: 0.000006},
    codex_exec: %{input_rate: 0.000001, output_rate: 0.000004},
    amp: %{input_rate: 0.0000018, output_rate: 0.0000072}
  }

  @model_rates %{
    {:claude, "claude-3-5-sonnet"} => %{input_rate: 0.000003, output_rate: 0.000015},
    {:claude, "claude-3-7-sonnet"} => %{input_rate: 0.000003, output_rate: 0.000015},
    {:gemini, "gemini-2.5-pro"} => %{input_rate: 0.000002, output_rate: 0.000008},
    {:gemini, "gemini-2.5-flash"} => %{input_rate: 0.000001, output_rate: 0.000004},
    {:codex_exec, "gpt-5-codex"} => %{input_rate: 0.000001, output_rate: 0.000004},
    {:amp, "amp-1"} => %{input_rate: 0.0000015, output_rate: 0.000006}
  }

  @spec lookup(atom(), String.t() | nil) :: rates()
  def lookup(provider, model) when is_atom(provider) do
    provider = canonical_provider(provider)
    model_key = normalize_model(model)
    Map.get(@model_rates, {provider, model_key}, Map.get(@defaults, provider, fallback_rates()))
  end

  defp canonical_provider(:codex), do: :codex_exec
  defp canonical_provider(other), do: other

  defp normalize_model(nil), do: ""
  defp normalize_model(model) when is_binary(model), do: String.trim(model)
  defp normalize_model(other), do: to_string(other)

  defp fallback_rates, do: %{input_rate: 0.000001, output_rate: 0.000001}
end
