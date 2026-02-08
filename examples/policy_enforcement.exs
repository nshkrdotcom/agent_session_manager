defmodule PolicyEnforcementExample do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Policy.Policy
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager

  @prompt "Reply in one short sentence about policy enforcement."

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Policy Enforcement Example (#{provider}) ===")
    IO.puts("")

    case run(provider) do
      :ok ->
        IO.puts("\nPolicy enforcement example passed.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nPolicy enforcement example failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run(provider) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider),
         {:ok, cancel_policy} <- build_policy(:cancel),
         {:ok, warn_policy} <- build_policy(:warn),
         {:ok, cancel_summary} <- run_cancel_mode(store, adapter, provider, cancel_policy),
         {:ok, warn_summary} <- run_warn_mode(store, adapter, provider, warn_policy) do
      print_summary(cancel_summary, warn_summary)
      :ok
    end
  end

  defp build_policy(action) when action in [:cancel, :warn] do
    Policy.new(
      name: "example-#{action}",
      limits: [{:max_duration_ms, 0}],
      tool_rules: [{:deny, ["bash"]}],
      on_violation: action,
      metadata: %{mode: action}
    )
  end

  defp run_cancel_mode(store, adapter, provider, policy) do
    with {:ok, session} <- start_session(store, adapter, provider, "cancel"),
         {:ok, run} <- start_prompt_run(store, adapter, session.id),
         {:error, %Error{code: :policy_violation}} <-
           SessionManager.execute_run(store, adapter, run.id, policy: policy),
         {:ok, events} <- SessionStore.get_events(store, session.id, run_id: run.id) do
      violation_count = Enum.count(events, &(&1.type == :policy_violation))

      if violation_count > 0 do
        {:ok,
         %{
           mode: :cancel,
           session_id: session.id,
           run_id: run.id,
           policy_violation_events: violation_count
         }}
      else
        {:error, Error.new(:internal_error, "cancel mode emitted no policy_violation events")}
      end
    end
  end

  defp run_warn_mode(store, adapter, provider, policy) do
    with {:ok, session} <- start_session(store, adapter, provider, "warn"),
         {:ok, run} <- start_prompt_run(store, adapter, session.id),
         {:ok, result} <- SessionManager.execute_run(store, adapter, run.id, policy: policy),
         {:ok, events} <- SessionStore.get_events(store, session.id, run_id: run.id) do
      violation_count = Enum.count(events, &(&1.type == :policy_violation))
      violations = get_in(result, [:policy, :violations]) || []

      if violation_count > 0 and is_list(violations) and violations != [] do
        {:ok,
         %{
           mode: :warn,
           session_id: session.id,
           run_id: run.id,
           policy_violation_events: violation_count,
           returned_violations: length(violations),
           action: get_in(result, [:policy, :action])
         }}
      else
        {:error, Error.new(:internal_error, "warn mode did not return policy violation metadata")}
      end
    end
  end

  defp start_session(store, adapter, provider, mode) do
    with {:ok, session} <-
           SessionManager.start_session(store, adapter, %{
             agent_id: "policy-#{provider}-#{mode}",
             context: %{system_prompt: "You are concise."},
             tags: ["example", "policy", provider, mode]
           }),
         {:ok, _active} <- SessionManager.activate_session(store, session.id) do
      {:ok, session}
    end
  end

  defp start_prompt_run(store, adapter, session_id) do
    SessionManager.start_run(store, adapter, session_id, %{
      messages: [%{role: "user", content: @prompt}]
    })
  end

  defp print_summary(cancel_summary, warn_summary) do
    IO.puts("Cancel mode:")
    IO.puts("  session: #{cancel_summary.session_id}")
    IO.puts("  run: #{cancel_summary.run_id}")
    IO.puts("  policy_violation events: #{cancel_summary.policy_violation_events}")

    IO.puts("\nWarn mode:")
    IO.puts("  session: #{warn_summary.session_id}")
    IO.puts("  run: #{warn_summary.run_id}")
    IO.puts("  policy_violation events: #{warn_summary.policy_violation_events}")
    IO.puts("  returned violations: #{warn_summary.returned_violations}")
    IO.puts("  action: #{warn_summary.action}")
  end

  defp start_adapter("claude") do
    ClaudeAdapter.start_link([])
  end

  defp start_adapter("codex") do
    CodexAdapter.start_link(working_directory: File.cwd!())
  end

  defp start_adapter("amp") do
    AmpAdapter.start_link(cwd: File.cwd!())
  end

  defp start_adapter(provider) do
    {:error, Error.new(:validation_error, "unknown provider: #{provider}")}
  end

  defp parse_args(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        strict: [provider: :string, help: :boolean],
        aliases: [p: :provider, h: :help]
      )

    if opts[:help] do
      print_usage()
      System.halt(0)
    end

    provider = opts[:provider] || "claude"

    unless provider in ["claude", "codex", "amp"] do
      IO.puts(:stderr, "Unknown provider: #{provider}")
      print_usage()
      System.halt(1)
    end

    provider
  end

  defp print_usage do
    IO.puts("""
    Usage: mix run examples/policy_enforcement.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/policy_enforcement.exs --provider claude
      mix run examples/policy_enforcement.exs --provider codex
      mix run examples/policy_enforcement.exs --provider amp
    """)
  end
end

PolicyEnforcementExample.main(System.argv())
