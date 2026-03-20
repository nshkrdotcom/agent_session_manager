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
    usage = normalize_usage(Event.result_usage(event))

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
