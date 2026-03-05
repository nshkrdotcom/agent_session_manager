Code.require_file("live_support.exs", __DIR__)

defmodule ASM.Examples.LivePolicy do
  @moduledoc false

  alias ASM.{Error, Event}
  alias ASM.Examples.LiveSupport
  alias ASM.Extensions.Policy

  def run! do
    provider = provider_from_env()
    session_id = "live-policy-#{provider}-#{System.system_time(:millisecond)}"
    provider_opts = provider_opts(provider)
    budget_prompt = budget_prompt()
    tool_prompt = tool_prompt()

    LiveSupport.ensure_cli!(provider, Keyword.take(provider_opts, [:cli_path]))

    start_opts =
      provider_opts
      |> Keyword.put(:provider, provider)
      |> Keyword.put(:session_id, session_id)

    with {:ok, session} <- ASM.start_session(start_opts) do
      try do
        run_budget_scenario!(session, budget_prompt)
        run_tool_deny_scenario!(session, tool_prompt)
        IO.puts("\nlive policy example completed")
      after
        _ = ASM.stop_session(session)
      end
    else
      {:error, %Error{} = error} ->
        IO.puts("failed to start policy example session: #{Exception.message(error)}")
        System.halt(1)

      {:error, other} ->
        IO.puts("failed to start policy example session: #{inspect(other)}")
        System.halt(1)
    end
  end

  defp run_budget_scenario!(session, prompt) do
    policy = Policy.new!(max_output_tokens: 0, on_budget_violation: :warn)
    events = stream_with_policy(session, prompt, policy)
    result = ASM.Stream.final_result(events)

    if budget_violation?(events) do
      IO.puts("\n[policy budget-limit scenario] guardrail warning emitted as expected")
      LiveSupport.print_result(result)
    else
      IO.puts("\n[policy budget-limit scenario] no output budget violation was emitted")
      print_guardrail_events(events)
      System.halt(1)
    end
  end

  defp run_tool_deny_scenario!(session, prompt) do
    policy = Policy.new!(disallow_tools: ["bash"], on_tool_violation: :cancel)
    events = stream_with_policy(session, prompt, policy)
    result = ASM.Stream.final_result(events)

    if denied_tool_violation?(events) do
      IO.puts("\n[policy denied-tool scenario] guardrail cancellation emitted as expected")
      LiveSupport.print_result(result)
    else
      IO.puts("\n[policy denied-tool scenario] denied-tool policy did not trigger")
      IO.puts("provider did not emit a matching tool call for this prompt")
      print_guardrail_events(events)
      LiveSupport.print_result(result)
      System.halt(1)
    end
  end

  defp stream_with_policy(session, prompt, policy) do
    IO.puts("\n[prompt] #{prompt}")

    events =
      session
      |> ASM.stream(
        prompt,
        pipeline: [Policy.enforcer_plug(policy)]
      )
      |> Enum.to_list()

    Enum.each(events, &LiveSupport.print_event/1)
    events
  end

  defp budget_violation?(events) do
    Enum.any?(events, fn
      %Event{
        kind: :guardrail_triggered,
        payload: %ASM.Control.GuardrailTrigger{
          rule: "output_budget_exceeded",
          action: :warn
        }
      } ->
        true

      _ ->
        false
    end)
  end

  defp denied_tool_violation?(events) do
    Enum.any?(events, fn
      %Event{
        kind: :error,
        payload: %ASM.Message.Error{kind: :guardrail_blocked}
      } ->
        true

      %Event{
        kind: :guardrail_triggered,
        payload: %ASM.Control.GuardrailTrigger{
          rule: "tool_disallowed",
          action: :cancel
        }
      } ->
        true

      _ ->
        false
    end)
  end

  defp print_guardrail_events(events) do
    guardrails =
      Enum.filter(events, fn
        %Event{kind: :guardrail_triggered} -> true
        _ -> false
      end)

    if guardrails == [] do
      IO.puts("guardrail events: none")
    else
      IO.puts("guardrail events:")
      Enum.each(guardrails, &IO.puts("  - #{inspect(&1.payload)}"))
    end
  end

  defp budget_prompt do
    System.get_env(
      "ASM_POLICY_BUDGET_PROMPT",
      "Reply with exactly: POLICY_BUDGET_LIMIT_OK"
    )
  end

  defp tool_prompt do
    System.get_env(
      "ASM_POLICY_TOOL_PROMPT",
      "Use the bash tool to run `pwd` and return only the command output."
    )
  end

  defp provider_from_env do
    case System.get_env("ASM_POLICY_PROVIDER", "codex") do
      "claude" -> :claude
      "gemini" -> :gemini
      "codex" -> :codex
      other -> raise ArgumentError, "unsupported ASM_POLICY_PROVIDER=#{inspect(other)}"
    end
  end

  defp provider_opts(provider) do
    []
    |> put_opt(:permission_mode, System.get_env("ASM_PERMISSION_MODE") || "auto")
    |> put_opt(:model, model_for(provider))
    |> put_opt(:cli_path, cli_path_for(provider))
  end

  defp model_for(:claude), do: System.get_env("ASM_CLAUDE_MODEL")
  defp model_for(:gemini), do: System.get_env("ASM_GEMINI_MODEL")
  defp model_for(:codex), do: System.get_env("ASM_CODEX_MODEL")

  defp cli_path_for(:claude), do: System.get_env("CLAUDE_CLI_PATH")
  defp cli_path_for(:gemini), do: System.get_env("GEMINI_CLI_PATH")
  defp cli_path_for(:codex), do: System.get_env("CODEX_PATH")

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, ""), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end

ASM.Examples.LivePolicy.run!()
