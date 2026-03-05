defmodule ASM.Extensions.Workspace.ContractTest do
  use ASM.TestCase

  alias ASM.Extensions.Workspace
  alias ASM.Extensions.Workspace.{Diff, Snapshot}

  setup context do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "asm-workspace-ext-#{sanitize(context.test)}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(workspace)
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(workspace)
    end)

    {:ok, workspace: workspace}
  end

  test "snapshot/2 falls back to hash backend outside git repos", %{workspace: workspace} do
    a_path = Path.join(workspace, "a.txt")
    b_path = Path.join(workspace, "b.txt")

    File.write!(a_path, "alpha\n")

    assert {:ok, before_snapshot} = Workspace.snapshot(workspace, backend: :auto)
    assert before_snapshot.backend == :hash

    File.write!(a_path, "alpha changed\n")
    File.write!(b_path, "beta\n")

    assert {:ok, after_snapshot} = Workspace.snapshot(workspace, backend: :auto)
    assert {:ok, %Diff{} = diff} = Workspace.diff(before_snapshot, after_snapshot)

    assert diff.added == ["b.txt"]
    assert diff.modified == ["a.txt"]
    assert diff.deleted == []

    assert {:error, error} = Workspace.rollback(before_snapshot)
    assert error.domain == :runtime
  end

  test "git backend snapshot/diff/rollback restores pre-run state", %{workspace: workspace} do
    init_git_repo!(workspace)

    tracked_path = Path.join(workspace, "tracked.txt")
    untracked_path = Path.join(workspace, "notes.txt")
    added_path = Path.join(workspace, "new.txt")

    File.write!(tracked_path, "before\n")
    File.write!(untracked_path, "keep me\n")

    assert {:ok, before_snapshot} = Workspace.snapshot(workspace, backend: :git)
    assert before_snapshot.backend == :git

    File.write!(tracked_path, "after\n")
    File.rm!(untracked_path)
    File.write!(added_path, "new file\n")

    assert {:ok, after_snapshot} = Workspace.snapshot(workspace, backend: :git)
    assert {:ok, %Diff{} = diff} = Workspace.diff(before_snapshot, after_snapshot)

    assert "new.txt" in diff.added
    assert "notes.txt" in diff.deleted
    assert "tracked.txt" in diff.modified

    assert :ok = Workspace.rollback(before_snapshot)

    assert File.read!(tracked_path) == "before\n"
    assert File.read!(untracked_path) == "keep me\n"
    refute File.exists?(added_path)
  end

  test "rollback/2 preserves current workspace when target snapshot is invalid", %{
    workspace: workspace
  } do
    init_git_repo!(workspace)

    tracked_path = Path.join(workspace, "tracked.txt")

    File.write!(tracked_path, "safe state\n")

    invalid_snapshot = %Snapshot{
      id: "snapshot-invalid",
      backend: :git,
      root: workspace,
      fingerprint: "ffffffffffffffffffffffffffffffffffffffff",
      captured_at: DateTime.utc_now(),
      metadata: %{
        tree: "ffffffffffffffffffffffffffffffffffffffff",
        head: read_git_head!(workspace)
      }
    }

    assert {:error, _error} = Workspace.rollback(invalid_snapshot)
    assert File.read!(tracked_path) == "safe state\n"
  end

  defp init_git_repo!(workspace) do
    run_git!(workspace, ["init", "--quiet"])
    run_git!(workspace, ["config", "user.name", "ASM Workspace Test"])
    run_git!(workspace, ["config", "user.email", "asm-workspace@example.com"])

    tracked_path = Path.join(workspace, "tracked.txt")
    File.write!(tracked_path, "committed base\n")

    run_git!(workspace, ["add", "tracked.txt"])
    run_git!(workspace, ["commit", "--quiet", "-m", "initial commit"])
  end

  defp read_git_head!(workspace) do
    workspace
    |> run_git!(["rev-parse", "HEAD"])
    |> String.trim()
  end

  defp run_git!(workspace, args) do
    case System.cmd("git", ["-C", workspace] ++ args, stderr_to_stdout: true) do
      {output, 0} ->
        output

      {output, status} ->
        flunk("git command failed (status=#{status}): git #{Enum.join(args, " ")}\n#{output}")
    end
  end

  defp sanitize(test_name) do
    test_name
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
  end
end
