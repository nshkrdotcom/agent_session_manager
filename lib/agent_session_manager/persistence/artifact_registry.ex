defmodule AgentSessionManager.Persistence.ArtifactRegistry do
  @moduledoc """
  Tracks artifact metadata in the `asm_artifacts` table.

  Provides registration, lookup, and statistics for artifacts
  stored in any backing store (S3, local filesystem, etc.).

  The registry only manages **metadata** — actual artifact content
  is handled by the `ArtifactStore` port.

  ## Usage

      {:ok, registry} = ArtifactRegistry.start_link(repo: MyApp.Repo)

      # Register an artifact after storing it
      :ok = ArtifactRegistry.register(registry, %{
        session_id: "ses_123",
        run_id: "run_456",
        key: "patches/fix.diff",
        byte_size: 1234,
        checksum_sha256: "abc123...",
        storage_backend: "s3",
        storage_ref: "s3://bucket/patches/fix.diff"
      })

      # List artifacts for a session
      {:ok, artifacts} = ArtifactRegistry.list_by_session(registry, "ses_123")

  """

  use GenServer

  import Ecto.Query

  alias AgentSessionManager.Adapters.EctoSessionStore.Schemas.ArtifactSchema
  alias AgentSessionManager.Core.Error

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts) do
    repo = Keyword.fetch!(opts, :repo)
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, %{repo: repo}, name: name)
  end

  @doc """
  Register artifact metadata.
  """
  @spec register(GenServer.server(), map()) :: :ok | {:error, Error.t()}
  def register(server, attrs) do
    GenServer.call(server, {:register, attrs})
  end

  @doc """
  Get artifact metadata by key.
  """
  @spec get_by_key(GenServer.server(), String.t()) ::
          {:ok, map() | nil} | {:error, Error.t()}
  def get_by_key(server, key) do
    GenServer.call(server, {:get_by_key, key})
  end

  @doc """
  List artifacts for a session.
  """
  @spec list_by_session(GenServer.server(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, Error.t()}
  def list_by_session(server, session_id, opts \\ []) do
    GenServer.call(server, {:list_by_session, session_id, opts})
  end

  @doc """
  Get aggregate stats for a session's artifacts.
  """
  @spec session_stats(GenServer.server(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  def session_stats(server, session_id) do
    GenServer.call(server, {:session_stats, session_id})
  end

  @doc """
  Soft-delete an artifact by key.
  """
  @spec delete(GenServer.server(), String.t()) :: :ok | {:error, Error.t()}
  def delete(server, key) do
    GenServer.call(server, {:delete, key})
  end

  # ============================================================================
  # GenServer
  # ============================================================================

  @impl GenServer
  def init(state), do: {:ok, state}

  @impl GenServer
  def handle_call({:register, attrs}, _from, %{repo: repo} = state) do
    {:reply, do_register(repo, attrs), state}
  end

  def handle_call({:get_by_key, key}, _from, %{repo: repo} = state) do
    {:reply, do_get_by_key(repo, key), state}
  end

  def handle_call({:list_by_session, session_id, opts}, _from, %{repo: repo} = state) do
    {:reply, do_list_by_session(repo, session_id, opts), state}
  end

  def handle_call({:session_stats, session_id}, _from, %{repo: repo} = state) do
    {:reply, do_session_stats(repo, session_id), state}
  end

  def handle_call({:delete, key}, _from, %{repo: repo} = state) do
    {:reply, do_delete(repo, key), state}
  end

  # ============================================================================
  # Implementation
  # ============================================================================

  defp do_register(repo, attrs) do
    id = Map.get(attrs, :id, "art_#{:crypto.strong_rand_bytes(12) |> Base.url_encode64()}")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    changeset_attrs = %{
      id: id,
      session_id: Map.get(attrs, :session_id),
      run_id: Map.get(attrs, :run_id),
      key: Map.fetch!(attrs, :key),
      content_type: Map.get(attrs, :content_type),
      byte_size: Map.fetch!(attrs, :byte_size),
      checksum_sha256: Map.fetch!(attrs, :checksum_sha256),
      storage_backend: Map.fetch!(attrs, :storage_backend),
      storage_ref: Map.fetch!(attrs, :storage_ref),
      metadata: Map.get(attrs, :metadata, %{}),
      created_at: now
    }

    changeset = ArtifactSchema.changeset(%ArtifactSchema{}, changeset_attrs)

    case repo.insert(changeset) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, Error.new(:validation_error, inspect(changeset.errors))}
    end
  rescue
    e -> {:error, Error.new(:persistence_error, Exception.message(e))}
  end

  defp do_get_by_key(repo, key) do
    case repo.one(from(a in ArtifactSchema, where: a.key == ^key and is_nil(a.deleted_at))) do
      nil -> {:ok, nil}
      schema -> {:ok, to_meta(schema)}
    end
  rescue
    e -> {:error, Error.new(:query_error, Exception.message(e))}
  end

  defp do_list_by_session(repo, session_id, _opts) do
    artifacts =
      repo.all(
        from(a in ArtifactSchema,
          where: a.session_id == ^session_id and is_nil(a.deleted_at),
          order_by: [asc: a.created_at]
        )
      )
      |> Enum.map(&to_meta/1)

    {:ok, artifacts}
  rescue
    e -> {:error, Error.new(:query_error, Exception.message(e))}
  end

  defp do_session_stats(repo, session_id) do
    stats =
      repo.one(
        from(a in ArtifactSchema,
          where: a.session_id == ^session_id and is_nil(a.deleted_at),
          select: %{
            count: count(a.id),
            total_bytes: sum(a.byte_size)
          }
        )
      )

    {:ok,
     %{
       artifact_count: stats.count,
       total_bytes: stats.total_bytes || 0
     }}
  rescue
    e -> {:error, Error.new(:query_error, Exception.message(e))}
  end

  defp do_delete(repo, key) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {_, _} =
      repo.update_all(
        from(a in ArtifactSchema, where: a.key == ^key and is_nil(a.deleted_at)),
        set: [deleted_at: now]
      )

    :ok
  rescue
    e -> {:error, Error.new(:persistence_error, Exception.message(e))}
  end

  defp to_meta(%ArtifactSchema{} = a) do
    %{
      id: a.id,
      session_id: a.session_id,
      run_id: a.run_id,
      key: a.key,
      content_type: a.content_type,
      byte_size: a.byte_size,
      checksum_sha256: a.checksum_sha256,
      storage_backend: a.storage_backend,
      storage_ref: a.storage_ref,
      metadata: a.metadata,
      created_at: a.created_at
    }
  end
end
