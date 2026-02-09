defmodule AgentSessionManager.Adapters.FileArtifactStore do
  @moduledoc """
  File-backed artifact store for local/dev usage.

  Stores artifacts as files in a configurable root directory.
  Keys are sanitized to safe filenames using hex encoding of the key hash
  combined with a readable prefix.

  ## Usage

      {:ok, store} = FileArtifactStore.start_link(root: "/tmp/asm_artifacts")
      :ok = ArtifactStore.put(store, "patch-abc123", "diff content...")
      {:ok, data} = ArtifactStore.get(store, "patch-abc123")

  ## Configuration

  - `:root` - Required. Root directory for artifact files.
  - `:name` - Optional. GenServer name for registration.
  """

  @behaviour AgentSessionManager.Ports.ArtifactStore

  use GenServer

  alias AgentSessionManager.Core.Error

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Starts the file artifact store.

  ## Options

  - `:root` - Required. Root directory for artifact storage.
  - `:name` - Optional. GenServer name.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case Keyword.fetch(opts, :root) do
      {:ok, root} when is_binary(root) and root != "" ->
        {name, remaining} = Keyword.pop(opts, :name)

        if name do
          GenServer.start_link(__MODULE__, remaining, name: name)
        else
          GenServer.start_link(__MODULE__, remaining)
        end

      _ ->
        {:error, Error.new(:validation_error, "root directory is required")}
    end
  end

  @doc "Stops the store."
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal)

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
  # GenServer Implementation
  # ============================================================================

  @impl GenServer
  def init(opts) do
    root = Keyword.fetch!(opts, :root)
    expanded = Path.expand(root)

    case File.mkdir_p(expanded) do
      :ok ->
        {:ok, %{root: expanded}}

      {:error, reason} ->
        {:stop, Error.new(:storage_error, "Failed to create artifact root: #{inspect(reason)}")}
    end
  end

  @impl GenServer
  def handle_call({:put_artifact, key, data, _opts}, _from, state) do
    path = artifact_path(state.root, key)
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, IO.iodata_to_binary(data)) do
      {:reply, :ok, state}
    else
      {:error, reason} ->
        {:reply,
         {:error, Error.new(:storage_error, "Failed to write artifact: #{inspect(reason)}")},
         state}
    end
  end

  @impl GenServer
  def handle_call({:get_artifact, key, _opts}, _from, state) do
    path = artifact_path(state.root, key)

    case File.read(path) do
      {:ok, data} ->
        {:reply, {:ok, data}, state}

      {:error, :enoent} ->
        {:reply, {:error, Error.new(:not_found, "Artifact not found: #{key}")}, state}

      {:error, reason} ->
        {:reply,
         {:error, Error.new(:storage_error, "Failed to read artifact: #{inspect(reason)}")},
         state}
    end
  end

  @impl GenServer
  def handle_call({:delete_artifact, key, _opts}, _from, state) do
    path = artifact_path(state.root, key)

    case File.rm(path) do
      :ok ->
        {:reply, :ok, state}

      {:error, :enoent} ->
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply,
         {:error, Error.new(:storage_error, "Failed to delete artifact: #{inspect(reason)}")},
         state}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp artifact_path(root, key) do
    # Use a hex-encoded hash for safe filesystem naming
    hash = :crypto.hash(:sha256, key) |> Base.encode16(case: :lower) |> binary_part(0, 16)

    safe_prefix =
      key |> String.replace(~r/[^a-zA-Z0-9_-]/, "_") |> binary_part(0, min(32, byte_size(key)))

    filename = "#{safe_prefix}_#{hash}"
    Path.join(root, filename)
  end
end
