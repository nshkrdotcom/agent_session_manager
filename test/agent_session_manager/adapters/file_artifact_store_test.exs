defmodule AgentSessionManager.Adapters.FileArtifactStoreTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.FileArtifactStore
  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Ports.ArtifactStore

  setup _ctx do
    root =
      Path.join(
        System.tmp_dir!(),
        "asm_artifact_test_#{System.unique_integer([:positive, :monotonic])}"
      )

    {:ok, store} = FileArtifactStore.start_link(root: root)
    cleanup_on_exit(fn -> safe_stop(store) end)
    cleanup_on_exit(fn -> File.rm_rf(root) end)

    %{store: store, root: root}
  end

  describe "put/get/delete roundtrip" do
    test "stores and retrieves binary data", %{store: store} do
      key = "test-artifact-001"
      data = "hello world artifact data"

      assert :ok = ArtifactStore.put(store, key, data)
      assert {:ok, ^data} = ArtifactStore.get(store, key)
    end

    test "overwrites existing key", %{store: store} do
      key = "overwrite-key"
      assert :ok = ArtifactStore.put(store, key, "original")
      assert :ok = ArtifactStore.put(store, key, "updated")
      assert {:ok, "updated"} = ArtifactStore.get(store, key)
    end

    test "delete removes artifact", %{store: store} do
      key = "delete-me"
      assert :ok = ArtifactStore.put(store, key, "to be deleted")
      assert :ok = ArtifactStore.delete(store, key)
      assert {:error, %Error{code: :not_found}} = ArtifactStore.get(store, key)
    end

    test "delete is idempotent for non-existent key", %{store: store} do
      assert :ok = ArtifactStore.delete(store, "nonexistent-key")
    end

    test "get returns error for non-existent key", %{store: store} do
      assert {:error, %Error{code: :not_found}} = ArtifactStore.get(store, "no-such-key")
    end

    test "handles iodata input", %{store: store} do
      key = "iodata-key"
      data = ["hello", " ", "world"]
      assert :ok = ArtifactStore.put(store, key, data)
      assert {:ok, "hello world"} = ArtifactStore.get(store, key)
    end

    test "handles binary data", %{store: store} do
      key = "binary-key"
      data = :crypto.strong_rand_bytes(1024)
      assert :ok = ArtifactStore.put(store, key, data)
      assert {:ok, ^data} = ArtifactStore.get(store, key)
    end
  end

  describe "start_link validation" do
    test "requires root option" do
      assert {:error, %Error{code: :validation_error}} = FileArtifactStore.start_link([])
    end
  end
end
