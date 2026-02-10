defmodule AgentSessionManager.Adapters.S3ArtifactStore do
  @moduledoc """
  An S3-backed implementation of the `ArtifactStore` port.

  Stores artifacts as objects in an S3-compatible bucket.
  Supports any S3-compatible storage (AWS S3, MinIO, DigitalOcean Spaces, etc).

  ## Configuration

      {:ok, store} = S3ArtifactStore.start_link(
        bucket: "my-artifacts-bucket",
        prefix: "asm/artifacts/",        # optional key prefix
        client: MyS3Client               # optional, defaults to ExAwsClient
      )

  ## Prerequisites

  Requires `{:ex_aws, "~> 2.5"}` and `{:ex_aws_s3, "~> 2.5"}` when using
  the default `ExAwsClient`. Configure ExAws with your AWS credentials.

  ## Key Structure

  Objects are stored with the configured prefix:

      {prefix}{key}

  For example, with `prefix: "asm/artifacts/"` and key `"patch-abc123"`:

      asm/artifacts/patch-abc123

  """

  @behaviour AgentSessionManager.Ports.ArtifactStore

  use GenServer

  alias AgentSessionManager.Core.Error

  # ============================================================================
  # Behaviour Implementation
  # ============================================================================

  @impl AgentSessionManager.Ports.ArtifactStore
  def put(store, key, data, opts \\ []) do
    GenServer.call(store, {:put_artifact, key, data, opts})
  end

  @impl AgentSessionManager.Ports.ArtifactStore
  def get(store, key, opts \\ []) do
    GenServer.call(store, {:get_artifact, key, opts})
  end

  @impl AgentSessionManager.Ports.ArtifactStore
  def delete(store, key, opts \\ []) do
    GenServer.call(store, {:delete_artifact, key, opts})
  end

  # ============================================================================
  # GenServer
  # ============================================================================

  def start_link(opts) do
    bucket = Keyword.fetch!(opts, :bucket)
    prefix = Keyword.get(opts, :prefix, "")
    client = Keyword.get(opts, :client, __MODULE__.ExAwsClient)
    name = Keyword.get(opts, :name)

    state = %{bucket: bucket, prefix: prefix, client: client}
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, state, gen_opts)
  end

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:put_artifact, key, data, opts}, _from, state) do
    s3_key = state.prefix <> key

    case state.client.put_object(state.bucket, s3_key, IO.iodata_to_binary(data), opts) do
      :ok ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply,
         {:error, Error.new(:storage_error, "Failed to put S3 object: #{inspect(reason)}")},
         state}
    end
  end

  def handle_call({:get_artifact, key, opts}, _from, state) do
    s3_key = state.prefix <> key

    case state.client.get_object(state.bucket, s3_key, opts) do
      {:ok, data} ->
        {:reply, {:ok, data}, state}

      {:error, :not_found} ->
        {:reply, {:error, Error.new(:not_found, "Artifact not found: #{key}")}, state}

      {:error, reason} ->
        {:reply,
         {:error, Error.new(:storage_error, "Failed to get S3 object: #{inspect(reason)}")},
         state}
    end
  end

  def handle_call({:delete_artifact, key, opts}, _from, state) do
    s3_key = state.prefix <> key

    case state.client.delete_object(state.bucket, s3_key, opts) do
      :ok ->
        {:reply, :ok, state}

      {:error, :not_found} ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply,
         {:error, Error.new(:storage_error, "Failed to delete S3 object: #{inspect(reason)}")},
         state}
    end
  end
end
