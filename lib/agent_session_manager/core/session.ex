defmodule AgentSessionManager.Core.Session do
  @moduledoc """
  Represents an AI agent session.

  A session is a logical container for a series of runs (interactions)
  with an AI agent. It maintains state, context, and metadata across
  multiple runs.

  ## Session Lifecycle

  Sessions follow this state machine:

      pending -> active -> completed
                       -> failed
                       -> cancelled
               -> paused -> active (resumed)

  ## Fields

  - `id` - Unique session identifier
  - `agent_id` - Identifier for the agent type/configuration
  - `status` - Current session status (:pending, :active, :paused, :completed, :failed, :cancelled)
  - `parent_session_id` - Optional parent session for hierarchical sessions
  - `metadata` - Arbitrary metadata associated with the session
  - `context` - Shared context data (system prompts, configuration)
  - `tags` - List of tags for categorization
  - `created_at` - Session creation timestamp
  - `updated_at` - Last update timestamp

  ## Usage

      # Create a new session
      {:ok, session} = Session.new(%{agent_id: "my-agent"})

      # Update status
      {:ok, active} = Session.update_status(session, :active)

      # Serialize for storage
      map = Session.to_map(session)

  """

  alias AgentSessionManager.Core.{Error, Serialization}

  @valid_statuses [:pending, :active, :paused, :completed, :failed, :cancelled]

  @type status :: :pending | :active | :paused | :completed | :failed | :cancelled

  @type t :: %__MODULE__{
          id: String.t() | nil,
          agent_id: String.t() | nil,
          status: status(),
          parent_session_id: String.t() | nil,
          metadata: map(),
          context: map(),
          tags: [String.t()],
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  defstruct [
    :id,
    :agent_id,
    :parent_session_id,
    :created_at,
    :updated_at,
    status: :pending,
    metadata: %{},
    context: %{},
    tags: []
  ]

  @doc """
  Creates a new session with the given attributes.

  ## Required

  - `:agent_id` - The agent identifier

  ## Optional

  - `:id` - Custom ID (auto-generated if not provided)
  - `:parent_session_id` - Parent session for hierarchical sessions
  - `:metadata` - Arbitrary metadata map
  - `:context` - Shared context data
  - `:tags` - List of string tags

  ## Examples

      iex> Session.new(%{agent_id: "my-agent"})
      {:ok, %Session{agent_id: "my-agent", status: :pending, ...}}

      iex> Session.new(%{})
      {:error, %Error{code: :validation_error, ...}}

  """
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, agent_id} <- validate_agent_id(attrs) do
      now = DateTime.utc_now()

      session = %__MODULE__{
        id: Map.get(attrs, :id) || generate_id(),
        agent_id: agent_id,
        status: :pending,
        parent_session_id: Map.get(attrs, :parent_session_id),
        metadata: Map.get(attrs, :metadata, %{}),
        context: Map.get(attrs, :context, %{}),
        tags: Map.get(attrs, :tags, []),
        created_at: now,
        updated_at: now
      }

      {:ok, session}
    end
  end

  @doc """
  Updates the session status.

  ## Valid statuses

  - `:pending` - Session created but not started
  - `:active` - Session is currently active
  - `:paused` - Session is paused
  - `:completed` - Session completed successfully
  - `:failed` - Session failed
  - `:cancelled` - Session was cancelled

  ## Examples

      iex> {:ok, session} = Session.new(%{agent_id: "agent"})
      iex> Session.update_status(session, :active)
      {:ok, %Session{status: :active, ...}}

      iex> Session.update_status(session, :invalid)
      {:error, %Error{code: :invalid_status}}

  """
  @spec update_status(t(), status()) :: {:ok, t()} | {:error, Error.t()}
  def update_status(%__MODULE__{} = session, status) when status in @valid_statuses do
    updated = %{session | status: status, updated_at: DateTime.utc_now()}
    {:ok, updated}
  end

  def update_status(%__MODULE__{}, status) do
    {:error,
     Error.new(
       :invalid_status,
       "Invalid status: #{inspect(status)}. Valid statuses: #{inspect(@valid_statuses)}"
     )}
  end

  @doc """
  Converts a session to a map suitable for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = session) do
    %{
      "id" => session.id,
      "agent_id" => session.agent_id,
      "status" => Atom.to_string(session.status),
      "parent_session_id" => session.parent_session_id,
      "metadata" => Serialization.stringify_keys(session.metadata),
      "context" => Serialization.stringify_keys(session.context),
      "tags" => session.tags,
      "created_at" => DateTime.to_iso8601(session.created_at),
      "updated_at" => DateTime.to_iso8601(session.updated_at)
    }
  end

  @doc """
  Reconstructs a session from a map.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map) when is_map(map) do
    with {:ok, id} <- get_required_string(map, "id"),
         {:ok, agent_id} <- get_required_string(map, "agent_id"),
         {:ok, status} <- parse_status(map["status"]),
         {:ok, created_at} <- parse_datetime(map["created_at"]),
         {:ok, updated_at} <- parse_datetime(map["updated_at"]) do
      session = %__MODULE__{
        id: id,
        agent_id: agent_id,
        status: status,
        parent_session_id: map["parent_session_id"],
        metadata: Serialization.atomize_keys(map["metadata"] || %{}),
        context: Serialization.atomize_keys(map["context"] || %{}),
        tags: map["tags"] || [],
        created_at: created_at,
        updated_at: updated_at
      }

      {:ok, session}
    end
  end

  def from_map(_), do: {:error, Error.new(:validation_error, "Invalid session map")}

  # Private helpers

  defp validate_agent_id(%{agent_id: agent_id}) when is_binary(agent_id) and agent_id != "" do
    {:ok, agent_id}
  end

  defp validate_agent_id(%{agent_id: ""}),
    do: {:error, Error.new(:validation_error, "agent_id cannot be empty")}

  defp validate_agent_id(_),
    do: {:error, Error.new(:validation_error, "agent_id is required")}

  defp generate_id do
    # Generate a UUID-like ID
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> then(&"ses_#{&1}")
  end

  defp get_required_string(map, key) do
    case Map.get(map, key) do
      nil -> {:error, Error.new(:validation_error, "#{key} is required")}
      "" -> {:error, Error.new(:validation_error, "#{key} cannot be empty")}
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, Error.new(:validation_error, "#{key} must be a string")}
    end
  end

  defp parse_status(nil), do: {:error, Error.new(:validation_error, "status is required")}

  defp parse_status(status) when is_binary(status) do
    atom = String.to_existing_atom(status)

    if atom in @valid_statuses do
      {:ok, atom}
    else
      {:error, Error.new(:invalid_status, "Invalid status: #{status}")}
    end
  rescue
    ArgumentError -> {:error, Error.new(:invalid_status, "Invalid status: #{status}")}
  end

  defp parse_status(_), do: {:error, Error.new(:validation_error, "status must be a string")}

  defp parse_datetime(nil), do: {:error, Error.new(:validation_error, "datetime is required")}

  defp parse_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> {:ok, dt}
      {:error, _} -> {:error, Error.new(:validation_error, "Invalid datetime format")}
    end
  end

  defp parse_datetime(_), do: {:error, Error.new(:validation_error, "datetime must be a string")}
end
