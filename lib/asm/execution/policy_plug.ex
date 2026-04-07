defmodule ASM.Execution.PolicyPlug do
  @moduledoc false

  @behaviour ASM.Pipeline.Plug

  alias ASM.{Error, Event}

  @impl true
  def call(%Event{kind: :tool_use} = event, ctx, opts) when is_map(ctx) and is_list(opts) do
    allowed_tools = Keyword.get(opts, :allowed_tools, [])
    payload = Event.legacy_payload(event)

    cond do
      allowed_tools == [] ->
        {:ok, event, ctx}

      payload.tool_name in allowed_tools ->
        {:ok, event, ctx}

      true ->
        {:error,
         Error.new(
           :guardrail_blocked,
           :guardrail,
           "Tool blocked by allowlist: #{payload.tool_name}",
           cause: %{tool_name: payload.tool_name, allowed_tools: allowed_tools}
         ), ctx}
    end
  end

  def call(event, ctx, _opts) do
    {:ok, event, ctx}
  end
end
