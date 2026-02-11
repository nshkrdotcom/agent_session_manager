defmodule ApprovalGatesExample do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Policy.Policy
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager

  @prompt "Delete the temporary files in /tmp/scratch."

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Approval Gates Example (#{provider}) ===")
    IO.puts("")

    case run(provider) do
      :ok ->
        IO.puts("\nApproval gates example passed.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nApproval gates example failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run(provider) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider) do
      demo_request_approval_flow(store, adapter)
    end
  end

  defp demo_request_approval_flow(store, adapter) do
    IO.puts("--- Part 1: on_violation: :request_approval ---")
    IO.puts("")

    # Create an approval-required policy
    {:ok, policy} =
      Policy.new(
        name: "production-safety",
        # Provider tool names can differ by casing (for example "Bash" vs "bash")
        tool_rules: [{:deny, ["bash", "Bash"]}],
        on_violation: :request_approval
      )

    IO.puts("  Policy: #{policy.name}")
    IO.puts("  Tool rules: #{inspect(policy.tool_rules)}")
    IO.puts("  On violation: #{policy.on_violation}")
    IO.puts("")

    # Start session and run
    {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "approval-demo"})
    {:ok, _active} = SessionManager.activate_session(store, session.id)

    {:ok, run} =
      SessionManager.start_run(store, adapter, session.id, %{
        messages: [%{role: "user", content: @prompt}]
      })

    IO.puts("  Session: #{session.id}")
    IO.puts("  Run: #{run.id}")
    IO.puts("")

    event_callback = fn event_data ->
      type = Map.get(event_data, :type, :unknown)
      IO.puts("  [event] #{type}")
    end

    # Execute with approval policy
    result =
      SessionManager.execute_run(store, adapter, run.id,
        policy: policy,
        event_callback: event_callback
      )

    IO.puts("")

    case result do
      {:ok, result_data} ->
        IO.puts("  Run completed (request_approval does NOT cancel)")

        if is_map(result_data[:policy]) do
          IO.puts("  Policy metadata present:")
          IO.puts("    Action: #{result_data.policy.action}")
          IO.puts("    Violations: #{length(result_data.policy.violations)}")
        end

      {:error, error} ->
        IO.puts("  Run failed: #{inspect(error)}")
    end

    IO.puts("")

    # Check for approval events
    {:ok, events} = SessionStore.get_events(store, session.id, run_id: run.id)

    approval_events = Enum.filter(events, &(&1.type == :tool_approval_requested))
    violation_events = Enum.filter(events, &(&1.type == :policy_violation))

    IO.puts("  Policy violation events: #{length(violation_events)}")
    IO.puts("  Approval requested events: #{length(approval_events)}")

    for evt <- approval_events do
      IO.puts("    Tool: #{evt.data[:tool_name] || evt.data["tool_name"]}")
      IO.puts("    Policy: #{evt.data[:policy_name] || evt.data["policy_name"]}")
      IO.puts("    Violation kind: #{evt.data[:violation_kind] || evt.data["violation_kind"]}")
    end

    IO.puts("")

    # Part 2: Demonstrate cancel_for_approval helper
    IO.puts("--- Part 2: cancel_for_approval helper ---")
    IO.puts("")

    {:ok, run2} =
      SessionManager.start_run(store, adapter, session.id, %{
        messages: [
          %{
            role: "user",
            content:
              "Count from 1 to 100 with one line per number and include a short explanation after each."
          }
        ]
      })

    parent = self()

    run2_task =
      Task.async(fn ->
        SessionManager.execute_run(store, adapter, run2.id,
          event_callback: fn event_data ->
            send(parent, {:run2_event, run2.id, Map.get(event_data, :type, :unknown)})
          end
        )
      end)

    approval_data = %{
      tool_name: "bash",
      tool_call_id: "tc_demo",
      tool_input: %{command: "ls /home"},
      policy_name: "production-safety",
      violation_kind: :tool_denied
    }

    cancel_result =
      case wait_for_run_event(run2.id, :run_started, 10_000) do
        :ok ->
          SessionManager.cancel_for_approval(store, adapter, run2.id, approval_data)

        {:error, reason} ->
          {:error, reason}
      end

    case cancel_result do
      {:ok, _} ->
        IO.puts("  cancel_for_approval succeeded for in-flight run: #{run2.id}")

      {:error, error} ->
        code = if is_map(error), do: Map.get(error, :code), else: error
        IO.puts("  cancel_for_approval failed: #{inspect(code)}")
    end

    run2_result =
      case Task.yield(run2_task, 30_000) || Task.shutdown(run2_task, :brutal_kill) do
        {:ok, result} -> result
        nil -> {:error, :timeout}
      end

    IO.puts("  Run 2 execute result: #{inspect(summarize_result(run2_result))}")

    IO.puts("")

    # Check events for run2
    {:ok, events2} = SessionStore.get_events(store, session.id, run_id: run2.id)
    event_types = Enum.map(events2, & &1.type)
    IO.puts("  Run 2 event types: #{inspect(Enum.uniq(event_types))}")

    IO.puts("")

    # Part 3: Demonstrate policy stacking with request_approval
    IO.puts("--- Part 3: Policy stacking with request_approval ---")
    IO.puts("")

    {:ok, org_policy} =
      Policy.new(
        name: "org-security",
        tool_rules: [{:deny, ["rm", "curl"]}],
        on_violation: :cancel
      )

    {:ok, team_policy} =
      Policy.new(
        name: "team-review",
        tool_rules: [{:deny, ["bash", "Bash"]}],
        on_violation: :request_approval
      )

    merged = Policy.stack_merge([org_policy, team_policy])
    IO.puts("  Org policy: on_violation=#{org_policy.on_violation}")
    IO.puts("  Team policy: on_violation=#{team_policy.on_violation}")
    IO.puts("  Merged: on_violation=#{merged.on_violation} (cancel wins, strictest)")
    IO.puts("  Merged name: #{merged.name}")
    IO.puts("  Merged tool_rules: #{inspect(merged.tool_rules)}")

    IO.puts("")
    IO.puts("=== Summary ===")
    IO.puts("  1. :request_approval emits tool_approval_requested without cancelling")
    IO.puts("  2. cancel_for_approval combines cancel + approval event emission")
    IO.puts("  3. Policy stacking: cancel > request_approval > warn")
    IO.puts("")

    :ok
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

  defp start_adapter(other) do
    {:error, "Unknown provider: #{other}"}
  end

  defp parse_args(args) do
    {parsed, _, _} =
      OptionParser.parse(args, strict: [provider: :string], aliases: [p: :provider])

    Keyword.get(parsed, :provider, "claude")
  end

  defp wait_for_run_event(run_id, event_type, timeout_ms) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_for_run_event(run_id, event_type, timeout_ms, started_at)
  end

  defp do_wait_for_run_event(run_id, event_type, timeout_ms, started_at) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    remaining = max(timeout_ms - elapsed, 0)

    receive do
      {:run2_event, ^run_id, ^event_type} ->
        :ok

      {:run2_event, ^run_id, _other} ->
        do_wait_for_run_event(run_id, event_type, timeout_ms, started_at)
    after
      remaining ->
        {:error, :timeout_waiting_for_run_event}
    end
  end

  defp summarize_result({:ok, _result}), do: :ok
  defp summarize_result({:error, error}) when is_map(error), do: {:error, Map.get(error, :code)}
  defp summarize_result(other), do: other
end

ApprovalGatesExample.main(System.argv())
