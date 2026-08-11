defmodule ASM.Execution.PolicyPlug do
  @moduledoc """
  Enforces an `allowed_tools` allowlist against `:tool_use` events.

  Enforcement depends on the lane, because a `:tool_use` event does not mean
  the same thing on every one of them.

  A lane that declares the `:approval` capability has a decision point before
  the tool runs — it can be asked, and it can be told no. Blocking there
  prevents the action, which is what a guardrail is for. `claude` and `amp`
  declare it.

  A lane without it reports tools as items that have already completed.
  `codex exec` under a bypass permission mode runs its tools internally and
  reports them afterwards, so by the time the event arrives the tool has run:
  raising cannot prevent anything and can only kill a run that was working.
  That is not a guardrail, it is a delayed abort. On those lanes a non-matching
  tool is recorded on the event and in telemetry, and the run continues.

  With no `:lane_capabilities` option this stays fail-closed and blocks, because
  an unknown lane is not evidence that interception is impossible.
  """

  @behaviour ASM.Pipeline.Plug

  alias ASM.{Error, Event, Telemetry}

  # The capability that means "this lane can be asked before the tool runs".
  @interception_capability :approval

  @impl true
  def call(%Event{kind: :tool_use} = event, ctx, opts) when is_map(ctx) and is_list(opts) do
    allowed_tools = Keyword.get(opts, :allowed_tools, [])
    payload = Event.legacy_payload(event)

    cond do
      allowed_tools == [] ->
        {:ok, event, ctx}

      payload.tool_name in allowed_tools ->
        {:ok, event, ctx}

      enforcement(opts) == :block ->
        {:error,
         Error.new(
           :guardrail_blocked,
           :guardrail,
           "Tool blocked by allowlist: #{payload.tool_name}",
           cause: %{tool_name: payload.tool_name, allowed_tools: allowed_tools}
         ), ctx}

      true ->
        {:ok, record_guardrail(event, payload.tool_name, allowed_tools), ctx}
    end
  end

  def call(event, ctx, _opts) do
    {:ok, event, ctx}
  end

  @doc """
  Whether a lane with these capabilities can prevent a tool call or only observe it.
  """
  @spec enforcement_for([atom()]) :: :block | :record
  def enforcement_for(capabilities) when is_list(capabilities) do
    if @interception_capability in capabilities, do: :block, else: :record
  end

  defp enforcement(opts) do
    case Keyword.fetch(opts, :lane_capabilities) do
      {:ok, capabilities} when is_list(capabilities) -> enforcement_for(capabilities)
      _other -> :block
    end
  end

  defp record_guardrail(%Event{} = event, tool_name, allowed_tools) do
    record = %{
      rule: :allowed_tools,
      action: :recorded,
      reason: :lane_observes_tools_after_execution,
      tool_name: tool_name,
      allowed_tools: allowed_tools
    }

    Telemetry.execute([:asm, :guardrail, :recorded], %{}, %{
      run_id: event.run_id,
      session_id: event.session_id,
      provider: event.provider,
      tool_name: tool_name,
      allowed_tools: allowed_tools
    })

    %{event | metadata: Map.put(event.metadata, :guardrail, record)}
  end
end
