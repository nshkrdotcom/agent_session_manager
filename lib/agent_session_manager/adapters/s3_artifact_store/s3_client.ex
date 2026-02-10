defmodule AgentSessionManager.Adapters.S3ArtifactStore.S3Client do
  @moduledoc """
  Behaviour for S3 API operations.

  This behaviour abstracts the S3 client to allow mocking in tests.
  The default implementation uses `ExAws.S3`.

  ## Custom Implementations

  You can provide your own implementation:

      {:ok, store} = S3ArtifactStore.start_link(
        bucket: "my-bucket",
        client: MyCustomS3Client
      )

  """

  @type key :: String.t()

  @callback put_object(bucket :: String.t(), key(), data :: binary(), opts :: keyword()) ::
              :ok | {:error, term()}

  @callback get_object(bucket :: String.t(), key(), opts :: keyword()) ::
              {:ok, binary()} | {:error, term()}

  @callback delete_object(bucket :: String.t(), key(), opts :: keyword()) ::
              :ok | {:error, term()}
end
