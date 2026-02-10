#!/usr/bin/env elixir
# Persistence S3 (MinIO) Example
#
# Demonstrates S3ArtifactStore with a real MinIO instance.
# Requires a running MinIO server (Docker recommended).
#
# Prerequisites:
#   docker run -d --name minio \
#     -p 9000:9000 -p 9001:9001 \
#     -e MINIO_ROOT_USER=minioadmin \
#     -e MINIO_ROOT_PASSWORD=minioadmin \
#     minio/minio server /data --console-address ":9001"
#
# Usage:
#   MINIO_ROOT_USER=minioadmin MINIO_ROOT_PASSWORD=minioadmin \
#     mix run examples/persistence_s3_minio.exs

defmodule PersistenceS3Minio do
  @moduledoc false

  alias AgentSessionManager.Adapters.S3ArtifactStore
  alias AgentSessionManager.Ports.ArtifactStore

  @bucket "asm-demo-artifacts"

  def main(_args) do
    IO.puts("\n=== Persistence S3 (MinIO) Example ===\n")

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
    # 1. Configure ExAws for MinIO
    IO.puts("1. Configuring ExAws for MinIO")

    access_key = System.get_env("MINIO_ROOT_USER") || "minioadmin"
    secret_key = System.get_env("MINIO_ROOT_PASSWORD") || "minioadmin"
    endpoint = System.get_env("MINIO_ENDPOINT") || "http://localhost:9000"

    %URI{host: host, port: port, scheme: scheme} = URI.parse(endpoint)

    Application.put_env(:ex_aws, :access_key_id, access_key)
    Application.put_env(:ex_aws, :secret_access_key, secret_key)
    Application.put_env(:ex_aws, :region, "us-east-1")

    Application.put_env(:ex_aws, :s3, %{
      scheme: "#{scheme}://",
      host: host,
      port: port,
      region: "us-east-1"
    })

    IO.puts("   Endpoint: #{endpoint}")
    IO.puts("   Bucket: #{@bucket}")

    # 2. Check MinIO connectivity
    IO.puts("\n2. Checking MinIO connectivity")

    case check_minio_available(endpoint) do
      :ok ->
        IO.puts("   MinIO is reachable")

      {:error, reason} ->
        IO.puts("   MinIO not reachable: #{inspect(reason)}")
        IO.puts("\n   To start MinIO:")
        IO.puts("     docker run -d --name minio \\")
        IO.puts("       -p 9000:9000 -p 9001:9001 \\")
        IO.puts("       -e MINIO_ROOT_USER=minioadmin \\")
        IO.puts("       -e MINIO_ROOT_PASSWORD=minioadmin \\")
        IO.puts("       minio/minio server /data --console-address \":9001\"")
        {:error, reason}
    end
    |> case do
      :ok -> run_with_minio()
      error -> error
    end
  end

  defp run_with_minio do
    # 3. Create bucket
    IO.puts("\n3. Creating bucket (if needed)")
    ensure_bucket(@bucket)
    IO.puts("   Bucket ready: #{@bucket}")

    # 4. Start S3ArtifactStore
    IO.puts("\n4. Starting S3ArtifactStore")

    {:ok, store} =
      S3ArtifactStore.start_link(
        bucket: @bucket,
        prefix: "sessions/"
      )

    IO.puts("   Store started with prefix: sessions/")

    # 5. Store artifacts
    IO.puts("\n5. Storing artifacts")

    artifacts = [
      {"workspace-snapshot-001", "Full workspace state at commit abc123..."},
      {"diff-patch-001",
       """
       diff --git a/lib/app.ex b/lib/app.ex
       index 1234567..abcdefg 100644
       --- a/lib/app.ex
       +++ b/lib/app.ex
       @@ -10,3 +10,5 @@ defmodule App do
          def hello, do: :world
       +
       +  def goodbye, do: :farewell
        end
       """},
      {"binary-artifact-001", :crypto.strong_rand_bytes(256)}
    ]

    for {key, data} <- artifacts do
      :ok = ArtifactStore.put(store, key, data)
      IO.puts("   PUT #{key} (#{byte_size(data)} bytes)")
    end

    # 6. Retrieve artifacts
    IO.puts("\n6. Retrieving artifacts")

    {:ok, snapshot} = ArtifactStore.get(store, "workspace-snapshot-001")
    IO.puts("   workspace-snapshot-001: #{byte_size(snapshot)} bytes")
    IO.puts("   Content: #{String.slice(snapshot, 0, 50)}...")

    {:ok, patch} = ArtifactStore.get(store, "diff-patch-001")
    IO.puts("   diff-patch-001: #{byte_size(patch)} bytes")

    {:ok, binary} = ArtifactStore.get(store, "binary-artifact-001")
    IO.puts("   binary-artifact-001: #{byte_size(binary)} bytes")

    # 7. Test not-found
    IO.puts("\n7. Testing not-found")
    {:error, error} = ArtifactStore.get(store, "nonexistent-key")
    IO.puts("   nonexistent-key: #{error.code}")

    # 8. Delete an artifact
    IO.puts("\n8. Deleting artifact")
    :ok = ArtifactStore.delete(store, "diff-patch-001")
    {:error, _} = ArtifactStore.get(store, "diff-patch-001")
    IO.puts("   diff-patch-001 deleted and verified gone")

    # 9. Idempotent delete
    IO.puts("\n9. Idempotent delete")
    :ok = ArtifactStore.delete(store, "diff-patch-001")
    IO.puts("   Second delete returned :ok")

    # 10. Cleanup
    IO.puts("\n10. Cleaning up")
    :ok = ArtifactStore.delete(store, "workspace-snapshot-001")
    :ok = ArtifactStore.delete(store, "binary-artifact-001")
    GenServer.stop(store)
    IO.puts("   All artifacts cleaned and store stopped")

    :ok
  end

  defp check_minio_available(endpoint) do
    uri = URI.parse("#{endpoint}/minio/health/live")

    case :httpc.request(:get, {~c"#{uri}", []}, [timeout: 3000], []) do
      {:ok, {{_, status, _}, _, _}} when status in 200..299 -> :ok
      {:ok, {{_, status, _}, _, _}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp ensure_bucket(bucket) do
    case ExAws.S3.head_bucket(bucket) |> ExAws.request() do
      {:ok, _} ->
        :ok

      {:error, _} ->
        case ExAws.S3.put_bucket(bucket, "us-east-1") |> ExAws.request() do
          {:ok, _} -> :ok
          {:error, reason} -> IO.puts("   Warning: bucket creation returned #{inspect(reason)}")
        end
    end
  end
end

# Ensure :inets and :ssl are started for :httpc
:inets.start()
:ssl.start()

PersistenceS3Minio.main(System.argv())
