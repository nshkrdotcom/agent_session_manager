defmodule AgentSessionManager.SessionManagerWorkspaceV2Test do
  @moduledoc """
  Phase 2 tests for artifact references in workspace metadata.
  When an artifact_store is configured, large patches are stored as artifacts
  and only a reference (patch_ref) is kept in run metadata.
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.FileArtifactStore
  alias AgentSessionManager.Ports.{ArtifactStore, SessionStore}
  alias AgentSessionManager.SessionManager

  defmodule ArtifactTestAdapter do
    @behaviour AgentSessionManager.Ports.ProviderAdapter

    alias AgentSessionManager.Core.Capability

    @impl true
    def name(_adapter), do: "artifact-test"

    @impl true
    def capabilities(_adapter) do
      {:ok, [%Capability{name: "chat", type: :tool, enabled: true}]}
    end

    @impl true
    def execute(_adapter, run, _session, opts) do
      # Modify a file in the workspace so there's a diff with a patch
      case Keyword.get(opts, :workspace_file) do
        nil -> :ok
        file -> File.write!(file, "modified by artifact-test adapter\n")
      end

      callback = Keyword.get(opts, :event_callback)

      if callback do
        callback.(%{
          type: :run_started,
          session_id: run.session_id,
          run_id: run.id,
          data: %{provider_session_id: "artifact-ses-1"},
          timestamp: DateTime.utc_now()
        })

        callback.(%{
          type: :run_completed,
          session_id: run.session_id,
          run_id: run.id,
          data: %{},
          timestamp: DateTime.utc_now()
        })
      end

      {:ok,
       %{
         output: %{content: "done"},
         token_usage: %{input_tokens: 1, output_tokens: 1},
         events: []
       }}
    end

    @impl true
    def cancel(_adapter, run_id), do: {:ok, run_id}

    @impl true
    def validate_config(_adapter, _config), do: :ok
  end

  setup ctx do
    {:ok, store} = setup_test_store(ctx)

    # Create artifact store
    artifact_root = create_temp_dir!("artifact_store")
    {:ok, artifact_store} = FileArtifactStore.start_link(root: artifact_root)
    cleanup_on_exit(fn -> safe_stop(artifact_store) end)

    {:ok, store: store, artifact_store: artifact_store, artifact_root: artifact_root}
  end

  describe "workspace with artifact_store" do
    test "stores patch in artifact store and returns patch_ref in metadata", ctx do
      repo = create_git_repo!()
      workspace_file = Path.join(repo, "file.txt")

      {:ok, session} =
        SessionManager.start_session(ctx.store, ArtifactTestAdapter, %{
          agent_id: "artifact-workspace-agent"
        })

      {:ok, _} = SessionManager.activate_session(ctx.store, session.id)

      {:ok, run} =
        SessionManager.start_run(ctx.store, ArtifactTestAdapter, session.id, %{prompt: "Go"})

      {:ok, result} =
        SessionManager.execute_run(ctx.store, ArtifactTestAdapter, run.id,
          adapter_opts: [workspace_file: workspace_file],
          workspace: [
            enabled: true,
            path: repo,
            strategy: :git,
            capture_patch: true,
            max_patch_bytes: 1_000_000,
            artifact_store: ctx.artifact_store
          ]
        )

      # The workspace result should have a patch_ref instead of embedded patch
      assert is_map(result.workspace)
      workspace_diff = result.workspace.diff
      assert is_binary(workspace_diff.patch_ref)
      assert workspace_diff.patch_ref != ""

      # patch_bytes should indicate the size
      assert is_integer(workspace_diff.patch_bytes)
      assert workspace_diff.patch_bytes > 0

      # The raw patch should NOT be embedded in the result
      assert workspace_diff.patch == nil

      # The artifact should be retrievable from the artifact store
      {:ok, stored_patch} = ArtifactStore.get(ctx.artifact_store, workspace_diff.patch_ref)
      assert is_binary(stored_patch)
      assert stored_patch != ""
      # The patch should contain our change
      assert String.contains?(stored_patch, "modified by artifact-test adapter")

      # Run metadata should also contain patch_ref
      {:ok, stored_run} = SessionStore.get_run(ctx.store, run.id)
      assert stored_run.metadata.workspace.diff.patch_ref == workspace_diff.patch_ref
    end

    test "skips artifact store when no patch captured (no changes)", ctx do
      repo = create_git_repo!()
      # Don't modify any files - clean workspace

      {:ok, session} =
        SessionManager.start_session(ctx.store, ArtifactTestAdapter, %{
          agent_id: "artifact-workspace-agent"
        })

      {:ok, _} = SessionManager.activate_session(ctx.store, session.id)

      {:ok, run} =
        SessionManager.start_run(ctx.store, ArtifactTestAdapter, session.id, %{prompt: "Go"})

      {:ok, result} =
        SessionManager.execute_run(ctx.store, ArtifactTestAdapter, run.id,
          adapter_opts: [],
          workspace: [
            enabled: true,
            path: repo,
            strategy: :git,
            capture_patch: true,
            artifact_store: ctx.artifact_store
          ]
        )

      # No changes = no patch_ref
      assert result.workspace.diff[:patch_ref] == nil
    end

    test "works without artifact_store (backward compat - patch embedded)", ctx do
      repo = create_git_repo!()
      workspace_file = Path.join(repo, "file.txt")

      {:ok, session} =
        SessionManager.start_session(ctx.store, ArtifactTestAdapter, %{
          agent_id: "artifact-workspace-agent"
        })

      {:ok, _} = SessionManager.activate_session(ctx.store, session.id)

      {:ok, run} =
        SessionManager.start_run(ctx.store, ArtifactTestAdapter, session.id, %{prompt: "Go"})

      {:ok, result} =
        SessionManager.execute_run(ctx.store, ArtifactTestAdapter, run.id,
          adapter_opts: [workspace_file: workspace_file],
          workspace: [
            enabled: true,
            path: repo,
            strategy: :git,
            capture_patch: true,
            max_patch_bytes: 1_000_000
          ]
        )

      # Without artifact_store, patch should be embedded directly
      assert is_binary(result.workspace.diff.patch)
      assert result.workspace.diff.patch != ""
      assert result.workspace.diff[:patch_ref] == nil
    end
  end

  defp create_git_repo! do
    repo = create_temp_dir!("ws_artifact_git")
    file_path = Path.join(repo, "file.txt")

    File.write!(file_path, "base\n")

    run_git!(repo, ["init"])
    run_git!(repo, ["config", "user.email", "test@example.com"])
    run_git!(repo, ["config", "user.name", "Test"])
    run_git!(repo, ["add", "file.txt"])
    run_git!(repo, ["commit", "-m", "initial"])

    repo
  end

  defp create_temp_dir!(prefix) do
    path =
      Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(path)
    cleanup_on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp run_git!(cwd, args) do
    {_output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    :ok
  end
end
