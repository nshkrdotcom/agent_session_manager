if Code.ensure_loaded?(ExAws) and Code.ensure_loaded?(ExAws.S3) do
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
else
  defmodule AgentSessionManager.Adapters.S3ArtifactStore.ExAwsClient do
    @moduledoc """
    Fallback S3 client used when optional ExAws dependencies are not installed.
    """

    @behaviour AgentSessionManager.Adapters.S3ArtifactStore.S3Client

    alias AgentSessionManager.OptionalDependency

    @impl true
    def put_object(_bucket, _key, _data, _opts),
      do: {:error, missing_dependency_error(:put_object)}

    @impl true
    def get_object(_bucket, _key, _opts), do: {:error, missing_dependency_error(:get_object)}

    @impl true
    def delete_object(_bucket, _key, _opts),
      do: {:error, missing_dependency_error(:delete_object)}

    defp missing_dependency_error(operation) do
      OptionalDependency.error(:ex_aws, __MODULE__, operation)
    end
  end
end
