defmodule WorkspaceSnapshotExample do
  @moduledoc false

  alias AgentSessionManager.Adapters.{
    AmpAdapter,
    ClaudeAdapter,
    CodexAdapter,
    InMemorySessionStore
  }

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Ports.SessionStore
  alias AgentSessionManager.SessionManager

  @success_prompt "Respond with one short sentence about workspace snapshots."
  @failure_prompt "Respond with one short sentence about rollback behavior."

  def main(args) do
    provider = parse_args(args)

    IO.puts("")
    IO.puts("=== Workspace Snapshot Example (#{provider}) ===")
    IO.puts("")

    case run(provider) do
      :ok ->
        IO.puts("\nWorkspace snapshot example passed.")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nWorkspace snapshot example failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run(provider) do
    {repo, workspace_file} = create_git_repo!()

    try do
      with {:ok, store} <- InMemorySessionStore.start_link([]),
           {:ok, adapter} <- start_adapter(provider),
           {:ok, session} <- start_session(store, adapter, provider),
           {:ok, success_run, success_result} <-
             execute_success_workspace_run(store, adapter, session.id, repo, workspace_file),
           :ok <- print_workspace_events(store, session.id, success_run.id, "success run"),
           :ok <- prepare_rollback_baseline(repo, workspace_file),
           :ok <- execute_failure_workspace_run(store, adapter, session.id, repo, workspace_file),
           :ok <- verify_rollback(workspace_file) do
        print_diff_summary(success_result)
        :ok
      end
    after
      File.rm_rf(repo)
    end
  end

  defp start_session(store, adapter, provider) do
    with {:ok, session} <-
           SessionManager.start_session(store, adapter, %{
             agent_id: "workspace-#{provider}",
             context: %{system_prompt: "You are concise and technical."},
             tags: ["example", "workspace", provider]
           }),
         {:ok, _active} <- SessionManager.activate_session(store, session.id) do
      {:ok, session}
    end
  end

  defp execute_success_workspace_run(store, adapter, session_id, repo, workspace_file) do
    success_callback = fn event ->
      if event.type == :run_started do
        File.write!(workspace_file, "changed during successful run\n")
      end
    end

    with {:ok, run} <-
           SessionManager.start_run(store, adapter, session_id, %{
             messages: [%{role: "user", content: @success_prompt}]
           }),
         {:ok, result} <-
           SessionManager.execute_run(store, adapter, run.id,
             event_callback: success_callback,
             workspace: [
               enabled: true,
               path: repo,
               strategy: :auto,
               capture_patch: true,
               max_patch_bytes: 250_000
             ]
           ) do
      {:ok, run, result}
    end
  end

  defp prepare_rollback_baseline(repo, workspace_file) do
    File.write!(workspace_file, "rollback-baseline\n")
    run_git!(repo, ["add", "file.txt"])

    case System.cmd("git", ["commit", "-m", "baseline before rollback run"],
           cd: repo,
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        :ok

      {output, _status} ->
        {:error,
         Error.new(:storage_error, "failed to commit rollback baseline: #{String.trim(output)}")}
    end
  end

  defp execute_failure_workspace_run(store, adapter, session_id, repo, workspace_file) do
    failing_callback = fn _event ->
      File.write!(workspace_file, "changed before forced failure\n")
      raise "forced workspace failure via event callback"
    end

    with {:ok, run} <-
           SessionManager.start_run(store, adapter, session_id, %{
             messages: [%{role: "user", content: @failure_prompt}]
           }) do
      case SessionManager.execute_run(store, adapter, run.id,
             event_callback: failing_callback,
             workspace: [
               enabled: true,
               path: repo,
               strategy: :git,
               capture_patch: true,
               max_patch_bytes: 250_000,
               rollback_on_failure: true
             ]
           ) do
        {:error, _error} ->
          print_workspace_events(store, session_id, run.id, "failure run")

        {:ok, _result} ->
          {:error, Error.new(:internal_error, "expected failure run to return an error")}
      end
    end
  end

  defp verify_rollback(workspace_file) do
    content = File.read!(workspace_file)

    if content == "rollback-baseline\n" do
      IO.puts("Rollback check: workspace restored to pre-run snapshot")
      :ok
    else
      {:error,
       Error.new(
         :internal_error,
         "rollback verification failed, current file content: #{inspect(content)}"
       )}
    end
  end

  defp print_workspace_events(store, session_id, run_id, label) do
    with {:ok, events} <- SessionStore.get_events(store, session_id, run_id: run_id) do
      workspace_events =
        Enum.filter(events, fn event ->
          event.type in [:workspace_snapshot_taken, :workspace_diff_computed]
        end)

      IO.puts("\nWorkspace events (#{label}):")

      Enum.each(workspace_events, fn event ->
        IO.puts("  #{event.type} #{inspect(event.data)}")
      end)

      :ok
    end
  end

  defp print_diff_summary(result) do
    workspace = Map.get(result, :workspace, %{})
    diff = Map.get(workspace, :diff, %{})

    IO.puts("\nWorkspace diff summary:")
    IO.puts("  backend: #{Map.get(workspace, :backend, :unknown)}")
    IO.puts("  files_changed: #{Map.get(diff, :files_changed, 0)}")
    IO.puts("  insertions: #{Map.get(diff, :insertions, 0)}")
    IO.puts("  deletions: #{Map.get(diff, :deletions, 0)}")
    IO.puts("  changed_paths: #{inspect(Map.get(diff, :changed_paths, []))}")
    IO.puts("  has_patch: #{is_binary(Map.get(diff, :patch))}")
  end

  defp create_git_repo! do
    repo =
      Path.join(
        System.tmp_dir!(),
        "workspace_example_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(repo)
    workspace_file = Path.join(repo, "file.txt")
    File.write!(workspace_file, "base\n")

    run_git!(repo, ["init"])
    run_git!(repo, ["config", "user.email", "example@test.local"])
    run_git!(repo, ["config", "user.name", "AgentSessionManager Example"])
    run_git!(repo, ["add", "file.txt"])
    run_git!(repo, ["commit", "-m", "initial workspace state"])

    {repo, workspace_file}
  end

  defp run_git!(cwd, args) do
    case System.cmd("git", args, cd: cwd, stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {output, _status} ->
        raise "git command failed: #{Enum.join(args, " ")}\n#{output}"
    end
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

    Usage: mix run examples/workspace_snapshot.exs [options]

    Options:
      --provider, -p <name>  Provider to use (claude, codex, or amp). Default: claude
      --help, -h             Show this help message

    Authentication:
      Claude: Run `claude login` or set ANTHROPIC_API_KEY
      Codex:  Run `codex login` or set CODEX_API_KEY
      Amp:    Run `amp login` or set AMP_API_KEY

    Examples:
      mix run examples/workspace_snapshot.exs --provider claude
      mix run examples/workspace_snapshot.exs --provider codex
      mix run examples/workspace_snapshot.exs --provider amp
    """)
  end
end

WorkspaceSnapshotExample.main(System.argv())
