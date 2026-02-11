defmodule AgentSessionManager.Persistence.ArtifactRegistryTest do
  use ExUnit.Case, async: false

  alias AgentSessionManager.Adapters.EctoSessionStore.Migration
  alias AgentSessionManager.Persistence.ArtifactRegistry

  defmodule ArtifactTestRepo do
    use Ecto.Repo, otp_app: :agent_session_manager, adapter: Ecto.Adapters.SQLite3
  end

  @db_path Path.join(System.tmp_dir!(), "asm_artifact_reg_test.db")

  setup_all do
    File.rm(@db_path)
    File.rm(@db_path <> "-wal")
    File.rm(@db_path <> "-shm")

    Application.put_env(:agent_session_manager, ArtifactTestRepo,
      database: @db_path,
      pool_size: 1
    )

    {:ok, repo_pid} = ArtifactTestRepo.start_link()
    Ecto.Migrator.up(ArtifactTestRepo, 1, Migration, log: false)

    on_exit(fn ->
      try do
        if Process.alive?(repo_pid), do: Supervisor.stop(repo_pid, :normal)
      catch
        :exit, _ -> :ok
      end

      File.rm(@db_path)
      File.rm(@db_path <> "-wal")
      File.rm(@db_path <> "-shm")
    end)

    :ok
  end

  setup do
    ArtifactTestRepo.delete_all(ArtifactRegistry.ArtifactSchema)

    {:ok, registry} = ArtifactRegistry.start_link(repo: ArtifactTestRepo)
    %{registry: registry}
  end

  test "uses ArtifactRegistry local schema module" do
    assert Code.ensure_loaded?(ArtifactRegistry.ArtifactSchema)
    assert function_exported?(ArtifactRegistry.ArtifactSchema, :changeset, 2)
  end

  defp artifact_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "ses_1",
        run_id: "run_1",
        key: "patches/fix_#{System.unique_integer([:positive])}.diff",
        byte_size: 1234,
        checksum_sha256: "abc123def456",
        storage_backend: "s3",
        storage_ref: "s3://bucket/patches/fix.diff",
        content_type: "text/plain"
      },
      overrides
    )
  end

  # ============================================================================
  # register
  # ============================================================================

  describe "register/2" do
    test "registers an artifact", %{registry: registry} do
      assert :ok = ArtifactRegistry.register(registry, artifact_attrs())
    end

    test "registers multiple artifacts", %{registry: registry} do
      :ok = ArtifactRegistry.register(registry, artifact_attrs(%{key: "file1.txt"}))
      :ok = ArtifactRegistry.register(registry, artifact_attrs(%{key: "file2.txt"}))

      {:ok, artifacts} = ArtifactRegistry.list_by_session(registry, "ses_1")
      assert length(artifacts) == 2
    end
  end

  # ============================================================================
  # get_by_key
  # ============================================================================

  describe "get_by_key/2" do
    test "retrieves artifact by key", %{registry: registry} do
      attrs = artifact_attrs(%{key: "unique_key.txt"})
      :ok = ArtifactRegistry.register(registry, attrs)

      {:ok, artifact} = ArtifactRegistry.get_by_key(registry, "unique_key.txt")
      assert artifact.key == "unique_key.txt"
      assert artifact.byte_size == 1234
      assert artifact.storage_backend == "s3"
    end

    test "returns nil for missing key", %{registry: registry} do
      {:ok, nil} = ArtifactRegistry.get_by_key(registry, "nonexistent")
    end
  end

  # ============================================================================
  # list_by_session
  # ============================================================================

  describe "list_by_session/3" do
    test "lists artifacts for a session", %{registry: registry} do
      :ok =
        ArtifactRegistry.register(registry, artifact_attrs(%{key: "a.txt", session_id: "ses_1"}))

      :ok =
        ArtifactRegistry.register(registry, artifact_attrs(%{key: "b.txt", session_id: "ses_1"}))

      :ok =
        ArtifactRegistry.register(registry, artifact_attrs(%{key: "c.txt", session_id: "ses_2"}))

      {:ok, artifacts} = ArtifactRegistry.list_by_session(registry, "ses_1")
      assert length(artifacts) == 2
    end

    test "returns empty list for unknown session", %{registry: registry} do
      {:ok, []} = ArtifactRegistry.list_by_session(registry, "nonexistent")
    end
  end

  # ============================================================================
  # session_stats
  # ============================================================================

  describe "session_stats/2" do
    test "returns count and total bytes", %{registry: registry} do
      :ok = ArtifactRegistry.register(registry, artifact_attrs(%{key: "a.txt", byte_size: 100}))
      :ok = ArtifactRegistry.register(registry, artifact_attrs(%{key: "b.txt", byte_size: 200}))

      {:ok, stats} = ArtifactRegistry.session_stats(registry, "ses_1")
      assert stats.artifact_count == 2
      assert stats.total_bytes == 300
    end

    test "returns zeros for empty session", %{registry: registry} do
      {:ok, stats} = ArtifactRegistry.session_stats(registry, "nonexistent")
      assert stats.artifact_count == 0
      assert stats.total_bytes == 0
    end
  end

  # ============================================================================
  # delete (soft)
  # ============================================================================

  describe "delete/2" do
    test "soft-deletes an artifact", %{registry: registry} do
      :ok = ArtifactRegistry.register(registry, artifact_attrs(%{key: "to_delete.txt"}))
      :ok = ArtifactRegistry.delete(registry, "to_delete.txt")

      {:ok, nil} = ArtifactRegistry.get_by_key(registry, "to_delete.txt")
    end

    test "is idempotent for missing key", %{registry: registry} do
      :ok = ArtifactRegistry.delete(registry, "nonexistent")
    end
  end
end
