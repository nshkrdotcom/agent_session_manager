defmodule AgentSessionManager.Workspace.HashBackendV2Test do
  @moduledoc """
  Phase 2 tests for hash backend configurable ignore rules.
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Workspace.HashBackend

  describe "configurable ignore rules" do
    test "default ignores exclude .git, deps, _build, node_modules" do
      dir = create_workspace!()

      # Add files in default-excluded directories
      File.mkdir_p!(Path.join(dir, ".git/objects"))
      File.write!(Path.join(dir, ".git/objects/dummy"), "data")
      File.mkdir_p!(Path.join(dir, "deps/dep_a"))
      File.write!(Path.join(dir, "deps/dep_a/mix.exs"), "dep")
      File.mkdir_p!(Path.join(dir, "_build/dev"))
      File.write!(Path.join(dir, "_build/dev/lib.ex"), "build")
      File.mkdir_p!(Path.join(dir, "node_modules/foo"))
      File.write!(Path.join(dir, "node_modules/foo/index.js"), "mod")

      {:ok, snapshot} = HashBackend.take_snapshot(dir)

      file_hashes = snapshot.metadata[:file_hashes]

      # Default-excluded directories should not appear
      refute Enum.any?(Map.keys(file_hashes), &String.starts_with?(&1, ".git/"))
      refute Enum.any?(Map.keys(file_hashes), &String.starts_with?(&1, "deps/"))
      refute Enum.any?(Map.keys(file_hashes), &String.starts_with?(&1, "_build/"))
      refute Enum.any?(Map.keys(file_hashes), &String.starts_with?(&1, "node_modules/"))

      # The actual file should be present
      assert Map.has_key?(file_hashes, "file.txt")
    end

    test "custom ignore paths exclude specified directories" do
      dir = create_workspace!()

      # Add a "vendor" directory
      File.mkdir_p!(Path.join(dir, "vendor/lib"))
      File.write!(Path.join(dir, "vendor/lib/ext.ex"), "vendor code")

      # Add a "logs" directory
      File.mkdir_p!(Path.join(dir, "logs"))
      File.write!(Path.join(dir, "logs/app.log"), "log data")

      {:ok, snapshot} =
        HashBackend.take_snapshot(dir, ignore: [paths: ["vendor", "logs"]])

      file_hashes = snapshot.metadata[:file_hashes]

      refute Enum.any?(Map.keys(file_hashes), &String.starts_with?(&1, "vendor/"))
      refute Enum.any?(Map.keys(file_hashes), &String.starts_with?(&1, "logs/"))
      assert Map.has_key?(file_hashes, "file.txt")
    end

    test "custom ignore paths are additive to defaults" do
      dir = create_workspace!()

      File.mkdir_p!(Path.join(dir, "node_modules/foo"))
      File.write!(Path.join(dir, "node_modules/foo/index.js"), "mod")

      File.mkdir_p!(Path.join(dir, "vendor"))
      File.write!(Path.join(dir, "vendor/ext.ex"), "vendor")

      {:ok, snapshot} =
        HashBackend.take_snapshot(dir, ignore: [paths: ["vendor"]])

      file_hashes = snapshot.metadata[:file_hashes]

      # Default excluded dirs are still excluded
      refute Enum.any?(Map.keys(file_hashes), &String.starts_with?(&1, "node_modules/"))
      # Custom excluded dirs are also excluded
      refute Enum.any?(Map.keys(file_hashes), &String.starts_with?(&1, "vendor/"))
      assert Map.has_key?(file_hashes, "file.txt")
    end

    test "custom ignore globs exclude matching files" do
      dir = create_workspace!()

      File.write!(Path.join(dir, "debug.log"), "log data")
      File.write!(Path.join(dir, "error.log"), "error log")
      File.write!(Path.join(dir, "app.txt"), "app data")
      File.mkdir_p!(Path.join(dir, "src"))
      File.write!(Path.join(dir, "src/main.ex"), "code")

      {:ok, snapshot} =
        HashBackend.take_snapshot(dir, ignore: [globs: ["*.log"]])

      file_hashes = snapshot.metadata[:file_hashes]

      refute Map.has_key?(file_hashes, "debug.log")
      refute Map.has_key?(file_hashes, "error.log")
      assert Map.has_key?(file_hashes, "file.txt")
      assert Map.has_key?(file_hashes, "app.txt")
      assert Map.has_key?(file_hashes, "src/main.ex")
    end

    test "ignore globs can match nested paths" do
      dir = create_workspace!()

      File.mkdir_p!(Path.join(dir, "src"))
      File.write!(Path.join(dir, "src/temp.bak"), "backup")
      File.write!(Path.join(dir, "src/main.ex"), "code")
      File.write!(Path.join(dir, "old.bak"), "old backup")

      {:ok, snapshot} =
        HashBackend.take_snapshot(dir, ignore: [globs: ["**/*.bak"]])

      file_hashes = snapshot.metadata[:file_hashes]

      refute Map.has_key?(file_hashes, "src/temp.bak")
      refute Map.has_key?(file_hashes, "old.bak")
      assert Map.has_key?(file_hashes, "src/main.ex")
      assert Map.has_key?(file_hashes, "file.txt")
    end

    test "empty ignore config uses only defaults" do
      dir = create_workspace!()

      File.mkdir_p!(Path.join(dir, "src"))
      File.write!(Path.join(dir, "src/main.ex"), "code")

      {:ok, snap_default} = HashBackend.take_snapshot(dir)
      {:ok, snap_empty} = HashBackend.take_snapshot(dir, ignore: [])

      assert snap_default.metadata[:file_hashes] == snap_empty.metadata[:file_hashes]
    end

    test "diff reflects ignore rules consistently" do
      dir = create_workspace!()

      {:ok, before_snap} =
        HashBackend.take_snapshot(dir, ignore: [paths: ["logs"]])

      # Add a file in the ignored directory
      File.mkdir_p!(Path.join(dir, "logs"))
      File.write!(Path.join(dir, "logs/app.log"), "log data")

      # Add a non-ignored file
      File.write!(Path.join(dir, "new_file.txt"), "new content")

      {:ok, after_snap} =
        HashBackend.take_snapshot(dir, ignore: [paths: ["logs"]])

      {:ok, diff} = HashBackend.diff(before_snap, after_snap)

      # Only the non-ignored file should appear in changed_paths
      assert "new_file.txt" in diff.changed_paths
      refute Enum.any?(diff.changed_paths, &String.starts_with?(&1, "logs/"))
    end
  end

  defp create_workspace! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "hash_v2_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "file.txt"), "base\n")

    cleanup_on_exit(fn -> File.rm_rf(dir) end)

    dir
  end
end
