defmodule AgentSessionManager.Ports.ArtifactStore do
  @moduledoc """
  Port (interface) for storing large blobs (patches, snapshot manifests).

  This behaviour defines the contract for artifact storage backends.
  Artifacts are referenced by string keys and contain binary data.

  ## Design Principles

  - **Key-value semantics**: Simple put/get/delete by string key
  - **Binary payloads**: Artifacts are opaque binary data
  - **Idempotent writes**: Putting the same key twice overwrites safely
  - **Pluggable backends**: File-based, S3, etc.

  ## Usage

      {:ok, store} = FileArtifactStore.start_link(root: "/tmp/artifacts")
      :ok = ArtifactStore.put(store, "patch-abc123", patch_data)
      {:ok, data} = ArtifactStore.get(store, "patch-abc123")
      :ok = ArtifactStore.delete(store, "patch-abc123")
  """

  alias AgentSessionManager.Core.Error

  @type store :: GenServer.server() | pid() | atom()
  @type key :: String.t()

  @doc """
  Stores binary data under the given key.

  Overwrites any existing data for the same key.

  ## Returns

  - `:ok` on success
  - `{:error, Error.t()}` on failure
  """
  @callback put(store(), key(), iodata(), keyword()) :: :ok | {:error, Error.t()}

  @doc """
  Retrieves binary data stored under the given key.

  ## Returns

  - `{:ok, binary()}` on success
  - `{:error, Error.t()}` when key not found or read fails
  """
  @callback get(store(), key(), keyword()) :: {:ok, binary()} | {:error, Error.t()}

  @doc """
  Deletes the artifact stored under the given key.

  Idempotent - deleting a non-existent key returns `:ok`.

  ## Returns

  - `:ok` on success
  - `{:error, Error.t()}` on failure
  """
  @callback delete(store(), key(), keyword()) :: :ok | {:error, Error.t()}

  # ============================================================================
  # Default implementations via GenServer delegation
  # ============================================================================

  @doc "Stores binary data under the given key."
  @spec put(store(), key(), iodata(), keyword()) :: :ok | {:error, Error.t()}
  def put(store, key, data, opts \\ []) do
    GenServer.call(store, {:put_artifact, key, data, opts})
  end

  @doc "Retrieves binary data stored under the given key."
  @spec get(store(), key(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def get(store, key, opts \\ []) do
    GenServer.call(store, {:get_artifact, key, opts})
  end

  @doc "Deletes the artifact stored under the given key."
  @spec delete(store(), key(), keyword()) :: :ok | {:error, Error.t()}
  def delete(store, key, opts \\ []) do
    GenServer.call(store, {:delete_artifact, key, opts})
  end
end
