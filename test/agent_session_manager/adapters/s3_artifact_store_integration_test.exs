defmodule AgentSessionManager.Adapters.S3ArtifactStoreIntegrationTest do
  @moduledoc """
  Integration tests for the S3ArtifactStore adapter.

  Uses an in-memory mock client to simulate S3 operations
  and tests the full put/get/delete lifecycle.
  """

  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Adapters.S3ArtifactStore
  alias AgentSessionManager.Core.Error
  alias AgentSessionManager.Ports.ArtifactStore

  # In-memory S3 client that stores data in an Agent for integration testing
  defmodule InMemoryS3Client do
    @behaviour AgentSessionManager.Adapters.S3ArtifactStore.S3Client

    def start_link do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    @impl true
    def put_object(bucket, key, data, _opts) do
      Agent.update(__MODULE__, &Map.put(&1, {bucket, key}, data))
      :ok
    end

    @impl true
    def get_object(bucket, key, _opts) do
      case Agent.get(__MODULE__, &Map.get(&1, {bucket, key})) do
        nil -> {:error, :not_found}
        data -> {:ok, data}
      end
    end

    @impl true
    def delete_object(bucket, key, _opts) do
      Agent.update(__MODULE__, &Map.delete(&1, {bucket, key}))
      :ok
    end
  end

  setup _ctx do
    {:ok, client_pid} = InMemoryS3Client.start_link()

    {:ok, store} =
      S3ArtifactStore.start_link(
        bucket: "integration-bucket",
        prefix: "test/",
        client: InMemoryS3Client
      )

    cleanup_on_exit(fn -> safe_stop(store) end)
    cleanup_on_exit(fn -> safe_stop(client_pid) end)

    %{store: store}
  end

  describe "full artifact lifecycle" do
    test "put, get, delete cycle", %{store: store} do
      key = "artifact-#{System.unique_integer([:positive])}"
      data = "Hello from S3 integration test!"

      # Put
      assert :ok = ArtifactStore.put(store, key, data)

      # Get
      assert {:ok, ^data} = ArtifactStore.get(store, key)

      # Delete
      assert :ok = ArtifactStore.delete(store, key)

      # Verify gone
      assert {:error, %Error{code: :not_found}} = ArtifactStore.get(store, key)
    end

    test "stores and retrieves binary data", %{store: store} do
      binary = :crypto.strong_rand_bytes(256)
      assert :ok = ArtifactStore.put(store, "binary-data", binary)
      assert {:ok, ^binary} = ArtifactStore.get(store, "binary-data")
    end

    test "overwrites existing key", %{store: store} do
      :ok = ArtifactStore.put(store, "overwrite-key", "first")
      :ok = ArtifactStore.put(store, "overwrite-key", "second")
      assert {:ok, "second"} = ArtifactStore.get(store, "overwrite-key")
    end

    test "delete is idempotent", %{store: store} do
      assert :ok = ArtifactStore.delete(store, "never-existed")
    end

    test "multiple artifacts are isolated", %{store: store} do
      :ok = ArtifactStore.put(store, "art-1", "data-1")
      :ok = ArtifactStore.put(store, "art-2", "data-2")

      assert {:ok, "data-1"} = ArtifactStore.get(store, "art-1")
      assert {:ok, "data-2"} = ArtifactStore.get(store, "art-2")

      :ok = ArtifactStore.delete(store, "art-1")
      assert {:error, _} = ArtifactStore.get(store, "art-1")
      assert {:ok, "data-2"} = ArtifactStore.get(store, "art-2")
    end
  end
end
