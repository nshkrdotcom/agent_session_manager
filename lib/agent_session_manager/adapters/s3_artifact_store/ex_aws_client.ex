defmodule AgentSessionManager.Adapters.S3ArtifactStore.ExAwsClient do
  @moduledoc """
  Default S3 client implementation using ExAws.

  Requires `{:ex_aws, "~> 2.5"}` and `{:ex_aws_s3, "~> 2.5"}` as dependencies.
  """

  @behaviour AgentSessionManager.Adapters.S3ArtifactStore.S3Client

  @impl true
  def put_object(bucket, key, data, _opts) do
    case ExAws.S3.put_object(bucket, key, data) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_object(bucket, key, _opts) do
    case ExAws.S3.get_object(bucket, key) |> ExAws.request() do
      {:ok, %{body: body}} -> {:ok, body}
      {:error, {:http_error, 404, _}} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete_object(bucket, key, _opts) do
    case ExAws.S3.delete_object(bucket, key) |> ExAws.request() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
