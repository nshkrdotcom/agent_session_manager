defmodule WorkflowBridgeExample do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Core.{Error, Session}
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.WorkflowBridge

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== WorkflowBridge Example (#{provider}) ===")
    IO.puts("")

    case run(provider) do
      :ok ->
        IO.puts("\nWorkflowBridge example passed.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nWorkflowBridge example failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run(provider) do
    with {:ok, store} <- InMemorySessionStore.start_link([]),
         {:ok, adapter} <- start_adapter(provider),
         :ok <- run_one_shot_step(store, adapter),
         :ok <- run_multi_step_workflow(store, adapter),
         :ok <- run_error_classification_demo() do
      :ok
    end
  end

  defp run_one_shot_step(store, adapter) do
    IO.puts("[1/3] One-shot step execution")

    with {:ok, result} <-
           WorkflowBridge.step_execute(store, adapter, %{
             input: %{messages: [%{role: "user", content: "What is 2+2?"}]}
           }) do
      IO.puts("  session_id: #{result.session_id}")
      IO.puts("  run_id: #{result.run_id}")
      IO.puts("  content: #{inspect(result.content)}")
      IO.puts("  stop_reason: #{inspect(result.stop_reason)}")
      IO.puts("  has_tool_calls: #{result.has_tool_calls}")
      IO.puts("  token_usage: #{inspect(result.token_usage)}")
      :ok
    end
  end

  defp run_multi_step_workflow(store, adapter) do
    IO.puts("\n[2/3] Multi-step workflow with shared session")

    with {:ok, session_id} <-
           WorkflowBridge.setup_workflow_session(store, adapter, %{
             agent_id: "workflow-demo",
             context: %{system_prompt: "You are concise. Follow instructions exactly."},
             tags: ["example", "workflow-bridge"]
           }),
         {:ok, r1} <-
           WorkflowBridge.step_execute(store, adapter, %{
             session_id: session_id,
             input: %{
               messages: [
                 %{role: "user", content: "Remember: SECRET-42. Reply: remembered."}
               ]
             }
           }),
         {:ok, r2} <-
           WorkflowBridge.step_execute(store, adapter, %{
             session_id: session_id,
             input: %{messages: [%{role: "user", content: "What secret did I tell you?"}]},
             continuation: :auto,
             continuation_opts: [max_messages: 20]
           }),
         :ok <- WorkflowBridge.complete_workflow_session(store, session_id),
         {:ok, session} <- SessionStore.get_session(store, session_id),
         {:ok, runs} <- SessionStore.list_runs(store, session_id) do
      IO.puts("  session_id: #{session_id}")
      IO.puts("  run_1: #{r1.run_id} -> #{inspect(r1.content)}")
      IO.puts("  run_2: #{r2.run_id} -> #{inspect(r2.content)}")
      IO.puts("  runs_in_session: #{length(runs)}")
      IO.puts("  session_status: #{session_status(session)}")
      :ok
    end
  end

  defp run_error_classification_demo do
    IO.puts("\n[3/3] Error classification demo")

    error = Error.new(:provider_timeout, "timed out")
    classification = WorkflowBridge.classify_error(error)

    IO.puts("  code: #{classification.error.code}")
    IO.puts("  category: #{classification.category}")
    IO.puts("  retryable: #{classification.retryable}")
    IO.puts("  recommended_action: #{classification.recommended_action}")
    :ok
  end

  defp session_status(%Session{status: status}), do: Atom.to_string(status)

  defp start_adapter("claude") do
    ClaudeAdapter.start_link([])
  end

  defp start_adapter("codex") do
    CodexAdapter.start_link(working_directory: File.cwd!())
  end

  defp start_adapter("amp") do
    AmpAdapter.start_link(cwd: File.cwd!())
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

    Usage: mix run examples/workflow_bridge.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/workflow_bridge.exs --provider claude
      mix run examples/workflow_bridge.exs --provider codex
      mix run examples/workflow_bridge.exs --provider amp
    """)
  end
end

WorkflowBridgeExample.main(System.argv())
