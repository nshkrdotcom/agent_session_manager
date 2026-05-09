defmodule ASM.Pipeline.CostTracker do
  @moduledoc """
  Pipeline plug that emits `:cost_update` control events from result usage.
  """

  @behaviour ASM.Pipeline.Plug

  alias ASM.Event
  alias CliSubprocessCore.Payload

  @impl true
  def call(%Event{kind: :result} = event, ctx, opts) do
    input_rate = Keyword.get(opts, :input_rate, 0.0)
    output_rate = Keyword.get(opts, :output_rate, 0.0)
    raw_usage = Event.result_usage(event)
    usage = normalize_usage(raw_usage)

    if delta_only_usage?(event, raw_usage) do
      {:ok, event, [], ctx}
    else
      cost =
        usage.input_tokens * input_rate +
          usage.output_tokens * output_rate

      prior_input = default_zero(get_in(ctx, [:cost, :input_tokens]))
      prior_output = default_zero(get_in(ctx, [:cost, :output_tokens]))
      prior_cost = default_zero(get_in(ctx, [:cost, :cost_usd]))

      totals = %{
        input_tokens: usage.input_tokens + prior_input,
        output_tokens: usage.output_tokens + prior_output,
        cost_usd: cost + prior_cost
      }

      cost_event = cost_event(event, usage.input_tokens, usage.output_tokens, cost)
      {:ok, event, [cost_event], Map.put(ctx, :cost, totals)}
    end
  end

  def call(event, ctx, _opts) do
    {:ok, event, ctx}
  end

  defp normalize_usage(usage) when is_map(usage) do
    %{
      input_tokens: Map.get(usage, :input_tokens) || Map.get(usage, "input_tokens") || 0,
      output_tokens: Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0
    }
  end

  defp normalize_usage(_), do: %{input_tokens: 0, output_tokens: 0}

  defp delta_only_usage?(%Event{} = event, usage) do
    usage_scope(event.metadata) in [:delta, :delta_only, :incremental] or
      usage_scope(usage) in [:delta, :delta_only, :incremental]
  end

  defp usage_scope(%{} = map) do
    map
    |> Map.get(
      :usage_scope,
      Map.get(map, "usage_scope", Map.get(map, :usage_kind, Map.get(map, "usage_kind")))
    )
    |> normalize_usage_scope()
  end

  defp usage_scope(_value), do: nil

  defp normalize_usage_scope(scope) when scope in [:delta, :delta_only, :incremental], do: scope

  defp normalize_usage_scope(scope) when is_binary(scope) do
    scope
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "delta" -> :delta
      "delta_only" -> :delta_only
      "incremental" -> :incremental
      _other -> nil
    end
  end

  defp normalize_usage_scope(_scope), do: nil

  defp cost_event(source_event, input_tokens, output_tokens, cost_usd) do
    Event.new(
      :cost_update,
      Payload.CostUpdate.new(
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        total_tokens: input_tokens + output_tokens,
        cost_usd: cost_usd
      ),
      run_id: source_event.run_id,
      session_id: source_event.session_id,
      provider: source_event.provider,
      correlation_id: source_event.id,
      causation_id: source_event.id,
      timestamp: DateTime.utc_now()
    )
  end

  defp default_zero(nil), do: 0
  defp default_zero(value), do: value
end
