defmodule ASM.Extensions.Policy.Enforcer do
  @moduledoc """
  Sync-only policy pipeline plug.

  Explicit violation handling:
  - `:warn` -> keep event and inject `:guardrail_triggered`
  - `:request_approval` -> halt source event and emit `:approval_requested`
  - `:cancel` -> reject with `%ASM.Error{}` (`:guardrail_blocked`)
  """

  @behaviour ASM.Pipeline.Plug

  alias ASM.{Control, Error, Event, Message}
  alias ASM.Extensions.Policy
  alias ASM.Extensions.Policy.Violation

  @impl true
  @spec call(Event.t(), map(), keyword()) ::
          {:ok, Event.t(), map()}
          | {:ok, Event.t(), [Event.t()], map()}
          | {:halt, Event.t(), [Event.t()], map()}
          | {:error, Error.t(), map()}
  def call(%Event{} = event, ctx, opts) when is_map(ctx) and is_list(opts) do
    case resolve_policy(opts) do
      {:ok, policy} ->
        case Policy.evaluate(policy, event, ctx) do
          {:ok, next_ctx} ->
            {:ok, event, next_ctx}

          {:violation, %Violation{} = violation, next_ctx} ->
            handle_violation(event, next_ctx, violation, opts)
        end

      {:error, %Error{} = error} ->
        {:error, error, ctx}
    end
  end

  defp resolve_policy(opts) do
    case Keyword.fetch(opts, :policy) do
      {:ok, policy} when is_struct(policy, Policy) ->
        {:ok, policy}

      {:ok, policy_opts} when is_list(policy_opts) ->
        Policy.new(policy_opts)

      :error ->
        Policy.new(opts)

      _invalid ->
        {:error,
         Error.new(:config_invalid, :config, "invalid :policy option for policy enforcer")}
    end
  end

  defp handle_violation(
         %Event{} = source_event,
         next_ctx,
         %Violation{action: :warn} = violation,
         opts
       ) do
    guardrail_event = guardrail_event(source_event, violation, opts)
    {:ok, source_event, [guardrail_event], put_last_violation(next_ctx, source_event, violation)}
  end

  defp handle_violation(
         %Event{} = source_event,
         next_ctx,
         %Violation{action: :request_approval} = violation,
         opts
       ) do
    approval_event = approval_event(source_event, violation, opts)
    guardrail_event = guardrail_event(source_event, violation, opts)

    {:halt, approval_event, [guardrail_event],
     put_last_violation(next_ctx, source_event, violation)}
  end

  defp handle_violation(
         %Event{} = source_event,
         next_ctx,
         %Violation{action: :cancel} = violation,
         _opts
       ) do
    {:error, Violation.to_error(violation, source_event),
     put_last_violation(next_ctx, source_event, violation)}
  end

  defp put_last_violation(ctx, %Event{} = source_event, %Violation{} = violation) do
    put_in(
      ctx,
      [Access.key(:policy, %{}), Access.key(:last_violation)],
      %{
        rule: violation.rule,
        action: violation.action,
        direction: violation.direction,
        message: violation.message,
        metadata: violation.metadata,
        source_event_id: source_event.id,
        source_event_kind: source_event.kind
      }
    )
  end

  defp guardrail_event(%Event{} = source_event, %Violation{} = violation, opts) do
    build_event(
      source_event,
      :guardrail_triggered,
      Violation.to_guardrail_trigger(violation),
      opts
    )
  end

  defp approval_event(%Event{} = source_event, %Violation{} = violation, opts) do
    approval_id_fun = approval_id_fun(opts)
    approval_id = approval_id_fun.(source_event, violation)
    {tool_name, tool_input} = approval_payload(source_event, violation)

    payload = %Control.ApprovalRequest{
      approval_id: approval_id,
      tool_name: tool_name,
      tool_input: tool_input
    }

    build_event(source_event, :approval_requested, payload, opts)
  end

  defp approval_payload(
         %Event{kind: :tool_use, payload: %Message.ToolUse{} = tool_use},
         _violation
       ) do
    {tool_use.tool_name, tool_use.input}
  end

  defp approval_payload(%Event{} = source_event, %Violation{} = violation) do
    tool_input = %{
      rule: normalize_rule(violation.rule),
      direction: violation.direction,
      source_event_kind: source_event.kind,
      metadata: violation.metadata
    }

    {"policy_violation", tool_input}
  end

  defp build_event(%Event{} = source_event, kind, payload, opts) do
    now_fun = now_fun(opts)

    %Event{
      id: Event.generate_id(),
      kind: kind,
      run_id: source_event.run_id,
      session_id: source_event.session_id,
      provider: source_event.provider,
      payload: payload,
      correlation_id: source_event.id,
      causation_id: source_event.id,
      timestamp: now_fun.()
    }
  end

  defp approval_id_fun(opts) do
    case Keyword.get(opts, :approval_id_fun) do
      fun when is_function(fun, 2) -> fun
      _ -> fn %Event{id: event_id}, _violation -> "policy-approval-#{event_id}" end
    end
  end

  defp now_fun(opts) do
    case Keyword.get(opts, :now_fun) do
      fun when is_function(fun, 0) -> fun
      _ -> &DateTime.utc_now/0
    end
  end

  defp normalize_rule(rule) when is_atom(rule), do: Atom.to_string(rule)
  defp normalize_rule(rule) when is_binary(rule), do: rule
end
