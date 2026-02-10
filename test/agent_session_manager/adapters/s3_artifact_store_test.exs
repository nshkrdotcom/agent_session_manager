defmodule AgentSessionManager.Adapters.S3ArtifactStoreTest do
  use AgentSessionManager.SupertesterCase, async: true

  import Mox

  alias AgentSessionManager.Adapters.S3ArtifactStore
  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.MockS3Client
  alias AgentSessionManager.Ports.ArtifactStore

  setup :set_mox_from_context
  setup :verify_on_exit!

  setup _ctx do
    {:ok, store} =
      S3ArtifactStore.start_link(
        bucket: "test-bucket",
        prefix: "asm/",
        client: MockS3Client
      )

    Mox.allow(MockS3Client, self(), store)

    cleanup_on_exit(fn -> safe_stop(store) end)

    %{store: store}
  end

  # ============================================================================
  # put/4
  # ============================================================================

  describe "put/4" do
    test "stores data in S3 with prefix", %{store: store} do
      expect(MockS3Client, :put_object, fn bucket, key, data, _opts ->
        assert bucket == "test-bucket"
        assert key == "asm/patch-abc123"
        assert data == "diff content"
        :ok
      end)

      assert :ok = ArtifactStore.put(store, "patch-abc123", "diff content")
    end

    test "handles binary iodata", %{store: store} do
      expect(MockS3Client, :put_object, fn _bucket, _key, data, _opts ->
        assert data == "hello world"
        :ok
      end)

      assert :ok = ArtifactStore.put(store, "key", ["hello", " ", "world"])
    end

    test "returns error on S3 failure", %{store: store} do
      expect(MockS3Client, :put_object, fn _bucket, _key, _data, _opts ->
        {:error, :access_denied}
      end)

      assert {:error, %Error{code: :storage_error}} =
               ArtifactStore.put(store, "key", "data")
    end

    test "overwrites existing key", %{store: store} do
      expect(MockS3Client, :put_object, 2, fn _bucket, key, data, _opts ->
        assert key == "asm/same-key"
        # S3 naturally overwrites
        assert data in ["first", "second"]
        :ok
      end)

      assert :ok = ArtifactStore.put(store, "same-key", "first")
      assert :ok = ArtifactStore.put(store, "same-key", "second")
    end
  end

  # ============================================================================
  # get/3
  # ============================================================================

  describe "get/3" do
    test "retrieves data from S3", %{store: store} do
      expect(MockS3Client, :get_object, fn bucket, key, _opts ->
        assert bucket == "test-bucket"
        assert key == "asm/my-artifact"
        {:ok, "stored data"}
      end)

      assert {:ok, "stored data"} = ArtifactStore.get(store, "my-artifact")
    end

    test "returns not_found error for missing key", %{store: store} do
      expect(MockS3Client, :get_object, fn _bucket, _key, _opts ->
        {:error, :not_found}
      end)

      assert {:error, %Error{code: :not_found}} =
               ArtifactStore.get(store, "nonexistent")
    end

    test "returns storage_error on S3 failure", %{store: store} do
      expect(MockS3Client, :get_object, fn _bucket, _key, _opts ->
        {:error, :timeout}
      end)

      assert {:error, %Error{code: :storage_error}} =
               ArtifactStore.get(store, "key")
    end

    test "retrieves binary data", %{store: store} do
      binary_data = <<0, 1, 2, 255, 128, 64>>

      expect(MockS3Client, :get_object, fn _bucket, _key, _opts ->
        {:ok, binary_data}
      end)

      assert {:ok, ^binary_data} = ArtifactStore.get(store, "binary-key")
    end
  end

  # ============================================================================
  # delete/3
  # ============================================================================

  describe "delete/3" do
    test "deletes object from S3", %{store: store} do
      expect(MockS3Client, :delete_object, fn bucket, key, _opts ->
        assert bucket == "test-bucket"
        assert key == "asm/to-delete"
        :ok
      end)

      assert :ok = ArtifactStore.delete(store, "to-delete")
    end

    test "is idempotent - deleting non-existent key returns :ok", %{store: store} do
      expect(MockS3Client, :delete_object, fn _bucket, _key, _opts ->
        {:error, :not_found}
      end)

      assert :ok = ArtifactStore.delete(store, "nonexistent")
    end

    test "returns error on S3 failure", %{store: store} do
      expect(MockS3Client, :delete_object, fn _bucket, _key, _opts ->
        {:error, :access_denied}
      end)

      assert {:error, %Error{code: :storage_error}} =
               ArtifactStore.delete(store, "key")
    end
  end

  # ============================================================================
  # Prefix handling
  # ============================================================================

  describe "key prefix" do
    test "no prefix when empty", _ctx do
      expect(MockS3Client, :put_object, fn _bucket, key, _data, _opts ->
        assert key == "raw-key"
        :ok
      end)

      {:ok, store} =
        S3ArtifactStore.start_link(
          bucket: "test-bucket",
          prefix: "",
          client: MockS3Client
        )

      Mox.allow(MockS3Client, self(), store)

      assert :ok = ArtifactStore.put(store, "raw-key", "data")
      safe_stop(store)
    end

    test "default prefix is empty", _ctx do
      expect(MockS3Client, :put_object, fn _bucket, key, _data, _opts ->
        assert key == "no-prefix"
        :ok
      end)

      {:ok, store} =
        S3ArtifactStore.start_link(
          bucket: "test-bucket",
          client: MockS3Client
        )

      Mox.allow(MockS3Client, self(), store)

      assert :ok = ArtifactStore.put(store, "no-prefix", "data")
      safe_stop(store)
    end
  end

  # ============================================================================
  # Full roundtrip
  # ============================================================================

  describe "put/get/delete roundtrip" do
    test "full lifecycle works", %{store: store} do
      # Put
      expect(MockS3Client, :put_object, fn _bucket, _key, data, _opts ->
        assert data == "important data"
        :ok
      end)

      assert :ok = ArtifactStore.put(store, "lifecycle-key", "important data")

      # Get
      expect(MockS3Client, :get_object, fn _bucket, _key, _opts ->
        {:ok, "important data"}
      end)

      assert {:ok, "important data"} = ArtifactStore.get(store, "lifecycle-key")

      # Delete
      expect(MockS3Client, :delete_object, fn _bucket, _key, _opts ->
        :ok
      end)

      assert :ok = ArtifactStore.delete(store, "lifecycle-key")

      # Verify gone
      expect(MockS3Client, :get_object, fn _bucket, _key, _opts ->
        {:error, :not_found}
      end)

      assert {:error, %Error{code: :not_found}} =
               ArtifactStore.get(store, "lifecycle-key")
    end
  end
end
