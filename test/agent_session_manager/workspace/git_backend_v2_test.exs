defmodule AgentSessionManager.Workspace.GitBackendV2Test do
  @moduledoc """
  Phase 2 tests for improved git snapshot including untracked files.
  """
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Workspace.GitBackend

  describe "take_snapshot/2 with untracked files" do
    test "snapshot includes untracked files without mutating HEAD" do
      repo = create_git_repo!()

      # Add an untracked file
      untracked_file = Path.join(repo, "untracked.txt")
      File.write!(untracked_file, "I am untracked\n")

      # Record HEAD before snapshot
      {head_before, 0} =
        System.cmd("git", ["-C", repo, "rev-parse", "HEAD"], stderr_to_stdout: true)

      head_before = String.trim(head_before)

      {:ok, snapshot} = GitBackend.take_snapshot(repo, label: :test)

      # HEAD should not have changed
      {head_after, 0} =
        System.cmd("git", ["-C", repo, "rev-parse", "HEAD"], stderr_to_stdout: true)

      head_after = String.trim(head_after)
      assert head_before == head_after

      # Snapshot should indicate it includes untracked
      assert snapshot.metadata[:includes_untracked] == true
      assert snapshot.metadata[:head_ref] == head_before

      # The ref should be a valid git object (commit)
      assert is_binary(snapshot.ref)
      assert snapshot.ref != ""

      # Untracked file should still exist (not cleaned up)
      assert File.exists?(untracked_file)

      # No stash entries should have been created
      {stash_list, 0} =
        System.cmd("git", ["-C", repo, "stash", "list"], stderr_to_stdout: true)

      assert String.trim(stash_list) == ""
    end

    test "diff between snapshots captures untracked file changes" do
      repo = create_git_repo!()

      {:ok, before_snap} = GitBackend.take_snapshot(repo, label: :before)

      # Add untracked file
      File.write!(Path.join(repo, "new_file.txt"), "new content\n")

      {:ok, after_snap} = GitBackend.take_snapshot(repo, label: :after)

      {:ok, diff} = GitBackend.diff(before_snap, after_snap, capture_patch: true)

      assert diff.files_changed >= 1
      assert "new_file.txt" in diff.changed_paths
    end

    test "snapshot without dirty changes shows dirty: false" do
      repo = create_git_repo!()

      {:ok, snapshot} = GitBackend.take_snapshot(repo, label: :clean)

      assert snapshot.metadata[:dirty] == false
    end

    test "snapshot with dirty changes shows dirty: true" do
      repo = create_git_repo!()
      File.write!(Path.join(repo, "file.txt"), "modified\n")

      {:ok, snapshot} = GitBackend.take_snapshot(repo, label: :dirty)

      assert snapshot.metadata[:dirty] == true
    end
  end

  defp create_git_repo! do
    repo =
      Path.join(
        System.tmp_dir!(),
        "git_v2_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(repo)
    file_path = Path.join(repo, "file.txt")
    File.write!(file_path, "base\n")

    run_git!(repo, ["init"])
    run_git!(repo, ["config", "user.email", "test@example.com"])
    run_git!(repo, ["config", "user.name", "Test"])
    run_git!(repo, ["add", "file.txt"])
    run_git!(repo, ["commit", "-m", "initial"])

    cleanup_on_exit(fn -> File.rm_rf(repo) end)

    repo
  end

  defp run_git!(cwd, args) do
    {_output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    :ok
  end
end
