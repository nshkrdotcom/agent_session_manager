defmodule ASM.Pipeline.PolicyGuard do
  @moduledoc """
  Pipeline plug that enforces lightweight policy checks on events.
  """

  @behaviour ASM.Pipeline.Plug

  alias ASM.Error
  alias ASM.Event
  @impl true
  def call(%Event{kind: :tool_use} = event, ctx, opts) do
    disallow_tools = Keyword.get(opts, :disallow_tools, [])
    payload = Event.legacy_payload(event)

    if payload.tool_name in disallow_tools do
      {:error,
       Error.new(:guardrail_blocked, :guardrail, "Tool blocked by policy: #{payload.tool_name}",
         cause: %{tool_name: payload.tool_name}
       ), ctx}
    else
      {:ok, event, ctx}
    end
  end

  def call(%Event{kind: :result} = event, ctx, opts) do
    max_output_tokens = Keyword.get(opts, :max_output_tokens)
    output_tokens = extract_output_tokens(Event.result_usage(event))

    cond do
      is_nil(max_output_tokens) ->
        {:ok, event, ctx}

      output_tokens > max_output_tokens ->
        {:error,
         Error.new(:guardrail_blocked, :guardrail, "Output tokens exceeded policy limit",
           cause: %{output_tokens: output_tokens, max_output_tokens: max_output_tokens}
         ), ctx}

      true ->
        {:ok, event, ctx}
    end
  end

  def call(event, ctx, _opts) do
    {:ok, event, ctx}
  end

  defp extract_output_tokens(usage) when is_map(usage) do
    Map.get(usage, :output_tokens) || Map.get(usage, "output_tokens") || 0
  end

  defp extract_output_tokens(_), do: 0
end
