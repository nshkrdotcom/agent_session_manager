defmodule AgentSessionManager.Workspace.WorkspaceTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Workspace.{Diff, Snapshot, Workspace}

  describe "backend detection" do
    test "detects git backend for git repositories" do
      repo = create_git_repo!()
      assert Workspace.detect_backend(repo) == :git
    end

    test "detects hash backend for non-git directories" do
      dir = create_plain_dir!()
      assert Workspace.detect_backend(dir) == :hash
    end
  end

  describe "snapshot and diff" do
    test "takes git snapshots and computes diff summary with patch" do
      repo = create_git_repo!()
      file_path = Path.join(repo, "file.txt")

      assert {:ok, %Snapshot{} = before_snapshot} =
               Workspace.take_snapshot(repo, strategy: :auto, label: :before)

      File.write!(file_path, "base\nchanged\n")

      assert {:ok, %Snapshot{} = after_snapshot} =
               Workspace.take_snapshot(repo, strategy: :auto, label: :after)

      assert {:ok, %Diff{} = diff} =
               Workspace.diff(before_snapshot, after_snapshot,
                 capture_patch: true,
                 max_patch_bytes: 100_000
               )

      assert diff.backend == :git
      assert diff.files_changed >= 1
      assert "file.txt" in diff.changed_paths
      assert is_binary(diff.patch)
      assert diff.patch != ""
    end

    test "omits full patch when max_patch_bytes is exceeded" do
      repo = create_git_repo!()
      file_path = Path.join(repo, "file.txt")

      assert {:ok, before_snapshot} =
               Workspace.take_snapshot(repo, strategy: :git, label: :before)

      File.write!(file_path, String.duplicate("line\n", 2_000))

      assert {:ok, after_snapshot} = Workspace.take_snapshot(repo, strategy: :git, label: :after)

      assert {:ok, %Diff{} = diff} =
               Workspace.diff(before_snapshot, after_snapshot,
                 capture_patch: true,
                 max_patch_bytes: 64
               )

      assert diff.patch == nil
      assert diff.metadata.patch_truncated == true
    end
  end

  describe "rollback" do
    test "rolls back git workspace to snapshot reference" do
      repo = create_git_repo!()
      file_path = Path.join(repo, "file.txt")

      assert {:ok, %Snapshot{} = snapshot} =
               Workspace.take_snapshot(repo, strategy: :git, label: :before)

      File.write!(file_path, "modified\n")
      assert File.read!(file_path) == "modified\n"

      assert :ok = Workspace.rollback(snapshot)
      assert File.read!(file_path) == "base\n"
    end

    test "returns config error when rollback requested for hash backend" do
      dir = create_plain_dir!()

      assert {:ok, %Snapshot{} = snapshot} =
               Workspace.take_snapshot(dir, strategy: :hash, label: :before)

      assert {:error, %Error{code: :invalid_operation}} = Workspace.rollback(snapshot)
    end
  end

  defp create_git_repo! do
    repo = create_temp_dir!("workspace_git")
    file_path = Path.join(repo, "file.txt")

    File.write!(file_path, "base\n")

    run_git!(repo, ["init"])
    run_git!(repo, ["config", "user.email", "test@example.com"])
    run_git!(repo, ["config", "user.name", "Agent Session Manager Test"])
    run_git!(repo, ["add", "file.txt"])
    run_git!(repo, ["commit", "-m", "initial commit"])

    repo
  end

  defp create_plain_dir! do
    dir = create_temp_dir!("workspace_hash")
    File.write!(Path.join(dir, "file.txt"), "plain\n")
    dir
  end

  defp create_temp_dir!(prefix) do
    path =
      Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive, :monotonic])}")

    File.mkdir_p!(path)
    cleanup_on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp run_git!(cwd, args) do
    {output, 0} = System.cmd("git", args, cd: cwd, stderr_to_stdout: true)
    output
  end
end
