#!/usr/bin/env elixir

defmodule S3ArtifactStoreLive do
  @moduledoc false

  alias AgentSessionManager.Adapters.S3ArtifactStore
  alias AgentSessionManager.Ports.ArtifactStore

  # In-memory S3 client for demonstration without real AWS credentials
  defmodule DemoS3Client do
    @behaviour AgentSessionManager.Adapters.S3ArtifactStore.S3Client

    def start_link do
      Agent.start_link(fn -> %{} end, name: __MODULE__)
    end

    @impl true
    def put_object(bucket, key, data, _opts) do
      Agent.update(__MODULE__, &Map.put(&1, {bucket, key}, data))
      IO.puts("     [S3] PUT #{bucket}/#{key} (#{byte_size(data)} bytes)")
      :ok
    end

    @impl true
    def get_object(bucket, key, _opts) do
      case Agent.get(__MODULE__, &Map.get(&1, {bucket, key})) do
        nil ->
          IO.puts("     [S3] GET #{bucket}/#{key} -> NOT FOUND")
          {:error, :not_found}

        data ->
          IO.puts("     [S3] GET #{bucket}/#{key} -> #{byte_size(data)} bytes")
          {:ok, data}
      end
    end

    @impl true
    def delete_object(bucket, key, _opts) do
      Agent.update(__MODULE__, &Map.delete(&1, {bucket, key}))
      IO.puts("     [S3] DELETE #{bucket}/#{key}")
      :ok
    end
  end

  def main(_args) do
    IO.puts("\n=== S3ArtifactStore Live Example ===\n")
    IO.puts("(Using in-memory mock S3 client for demo)\n")

    case run() do
      :ok ->
        IO.puts("\nAll checks passed!")
        System.halt(0)

      {:error, reason} ->
        IO.puts(:stderr, "\nError: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp run do
    # 1. Start mock S3 client
    IO.puts("1. Starting mock S3 client")
    {:ok, _} = DemoS3Client.start_link()

    # 2. Start S3ArtifactStore
    IO.puts("\n2. Starting S3ArtifactStore")

    {:ok, store} =
      S3ArtifactStore.start_link(
        bucket: "demo-bucket",
        prefix: "asm/artifacts/",
        client: DemoS3Client
      )

    IO.puts("   Store started: #{inspect(store)}")

    # 3. Store some artifacts
    IO.puts("\n3. Storing artifacts")
    :ok = ArtifactStore.put(store, "snapshot-001", "workspace snapshot data...")
    :ok = ArtifactStore.put(store, "patch-abc123", "diff --git a/file.ex b/file.ex\n...")
    :ok = ArtifactStore.put(store, "binary-data", :crypto.strong_rand_bytes(64))

    # 4. Retrieve artifacts
    IO.puts("\n4. Retrieving artifacts")
    {:ok, snapshot} = ArtifactStore.get(store, "snapshot-001")
    IO.puts("   snapshot-001: #{String.slice(snapshot, 0, 30)}...")

    {:ok, patch} = ArtifactStore.get(store, "patch-abc123")
    IO.puts("   patch-abc123: #{String.slice(patch, 0, 30)}...")

    # 5. Test not-found
    IO.puts("\n5. Testing not-found")
    {:error, error} = ArtifactStore.get(store, "nonexistent")
    IO.puts("   nonexistent: #{error.code} - #{error.message}")

    # 6. Delete an artifact
    IO.puts("\n6. Deleting artifact")
    :ok = ArtifactStore.delete(store, "patch-abc123")

    # Verify deleted
    {:error, _} = ArtifactStore.get(store, "patch-abc123")
    IO.puts("   Verified: patch-abc123 deleted")

    # 7. Idempotent delete
    IO.puts("\n7. Idempotent delete (already deleted)")
    :ok = ArtifactStore.delete(store, "patch-abc123")
    IO.puts("   Second delete returned :ok")

    GenServer.stop(store)
    :ok
  end
end

S3ArtifactStoreLive.main(System.argv())
