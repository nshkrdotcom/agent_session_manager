defmodule AgentSessionManager.Core.Run do
  @moduledoc """
  Represents a single execution run within a session.

  A run represents one complete interaction with the AI agent,
  including input, output, and any intermediate steps (turns).

  ## Run Lifecycle

  Runs follow this state machine:

      pending -> running -> completed
                        -> failed
                        -> cancelled
                        -> timeout

  ## Fields

  - `id` - Unique run identifier
  - `session_id` - Parent session identifier
  - `status` - Current run status
  - `input` - Input data for the run
  - `output` - Output data from the run
  - `error` - Error information if the run failed
  - `metadata` - Arbitrary metadata
  - `turn_count` - Number of turns in this run
  - `token_usage` - Token usage statistics
  - `started_at` - Run start timestamp
  - `ended_at` - Run end timestamp

  ## Usage

      # Create a new run
      {:ok, run} = Run.new(%{session_id: "session-123"})

      # Start the run
      {:ok, running} = Run.update_status(run, :running)

      # Set output and complete
      {:ok, completed} = Run.set_output(running, %{response: "Hello!"})

  """

  alias AgentSessionManager.Core.{Error, Serialization}

  @valid_statuses [:pending, :running, :completed, :failed, :cancelled, :timeout]
  @terminal_statuses [:completed, :failed, :cancelled, :timeout]

  @type status :: :pending | :running | :completed | :failed | :cancelled | :timeout

  @type t :: %__MODULE__{
          id: String.t() | nil,
          session_id: String.t() | nil,
          status: status(),
          input: map() | nil,
          output: map() | nil,
          error: map() | nil,
          metadata: map(),
          turn_count: non_neg_integer(),
          token_usage: map(),
          started_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          provider: String.t() | nil,
          provider_metadata: map()
        }

  defstruct [
    :id,
    :session_id,
    :input,
    :output,
    :error,
    :started_at,
    :ended_at,
    :provider,
    status: :pending,
    metadata: %{},
    turn_count: 0,
    token_usage: %{},
    provider_metadata: %{}
  ]

  @doc """
  Creates a new run with the given attributes.

  ## Required

  - `:session_id` - The parent session identifier

  ## Optional

  - `:id` - Custom ID (auto-generated if not provided)
  - `:input` - Input data for the run
  - `:metadata` - Arbitrary metadata map

  ## Examples

      iex> Run.new(%{session_id: "session-123"})
      {:ok, %Run{session_id: "session-123", status: :pending, ...}}

      iex> Run.new(%{})
      {:error, %Error{code: :validation_error, ...}}

  """
  @spec new(map()) :: {:ok, t()} | {:error, Error.t()}
  def new(attrs) when is_map(attrs) do
    with {:ok, session_id} <- validate_session_id(attrs) do
      run = %__MODULE__{
        id: Map.get(attrs, :id) || generate_id(),
        session_id: session_id,
        status: :pending,
        input: Map.get(attrs, :input),
        metadata: Map.get(attrs, :metadata, %{}),
        turn_count: 0,
        token_usage: %{},
        started_at: DateTime.utc_now()
      }

      {:ok, run}
    end
  end

  @doc """
  Updates the run status.

  ## Valid statuses

  - `:pending` - Run created but not started
  - `:running` - Run is currently executing
  - `:completed` - Run completed successfully
  - `:failed` - Run failed
  - `:cancelled` - Run was cancelled
  - `:timeout` - Run timed out

  Terminal statuses (:completed, :failed, :cancelled, :timeout) will
  automatically set the `ended_at` timestamp.

  ## Examples

      iex> {:ok, run} = Run.new(%{session_id: "session"})
      iex> Run.update_status(run, :running)
      {:ok, %Run{status: :running, ended_at: nil, ...}}

      iex> Run.update_status(run, :completed)
      {:ok, %Run{status: :completed, ended_at: %DateTime{}, ...}}

  """
  @spec update_status(t(), status()) :: {:ok, t()} | {:error, Error.t()}
  def update_status(%__MODULE__{} = run, status) when status in @valid_statuses do
    ended_at = if status in @terminal_statuses, do: DateTime.utc_now(), else: run.ended_at

    updated = %{run | status: status, ended_at: ended_at}
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
  Sets the output and marks the run as completed.
  """
  @spec set_output(t(), map()) :: {:ok, t()}
  def set_output(%__MODULE__{} = run, output) when is_map(output) do
    updated = %{run | output: output, status: :completed, ended_at: DateTime.utc_now()}
    {:ok, updated}
  end

  @doc """
  Sets the error and marks the run as failed.
  """
  @spec set_error(t(), map()) :: {:ok, t()}
  def set_error(%__MODULE__{} = run, error) when is_map(error) do
    updated = %{run | error: error, status: :failed, ended_at: DateTime.utc_now()}
    {:ok, updated}
  end

  @doc """
  Increments the turn count by 1.
  """
  @spec increment_turn(t()) :: {:ok, t()}
  def increment_turn(%__MODULE__{} = run) do
    updated = %{run | turn_count: run.turn_count + 1}
    {:ok, updated}
  end

  @doc """
  Updates token usage statistics.

  Token usage is accumulated across multiple updates.
  """
  @spec update_token_usage(t(), map()) :: {:ok, t()}
  def update_token_usage(%__MODULE__{} = run, usage) when is_map(usage) do
    merged =
      Map.merge(run.token_usage, usage, fn _k, v1, v2 ->
        if is_number(v1) and is_number(v2), do: v1 + v2, else: v2
      end)

    updated = %{run | token_usage: merged}
    {:ok, updated}
  end

  @doc """
  Converts a run to a map suitable for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = run) do
    %{
      "id" => run.id,
      "session_id" => run.session_id,
      "status" => Atom.to_string(run.status),
      "input" => Serialization.stringify_keys(run.input),
      "output" => Serialization.stringify_keys(run.output),
      "error" => Serialization.stringify_keys(run.error),
      "metadata" => Serialization.stringify_keys(run.metadata),
      "turn_count" => run.turn_count,
      "token_usage" => Serialization.stringify_keys(run.token_usage),
      "started_at" => format_datetime(run.started_at),
      "ended_at" => format_datetime(run.ended_at),
      "provider" => run.provider,
      "provider_metadata" => Serialization.stringify_keys(run.provider_metadata)
    }
  end

  @doc """
  Reconstructs a run from a map.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, Error.t()}
  def from_map(map) when is_map(map) do
    with {:ok, id} <- get_required_string(map, "id"),
         {:ok, session_id} <- get_required_string(map, "session_id"),
         {:ok, status} <- parse_status(map["status"]),
         {:ok, started_at} <- parse_datetime(map["started_at"]) do
      run = %__MODULE__{
        id: id,
        session_id: session_id,
        status: status,
        input: Serialization.atomize_keys(map["input"]),
        output: Serialization.atomize_keys(map["output"]),
        error: Serialization.atomize_keys(map["error"]),
        metadata: Serialization.atomize_keys(map["metadata"] || %{}),
        turn_count: map["turn_count"] || 0,
        token_usage: Serialization.atomize_keys(map["token_usage"] || %{}),
        started_at: started_at,
        ended_at: parse_optional_datetime(map["ended_at"]),
        provider: map["provider"],
        provider_metadata: Serialization.atomize_keys(map["provider_metadata"] || %{})
      }

      {:ok, run}
    end
  end

  def from_map(_), do: {:error, Error.new(:validation_error, "Invalid run map")}

  # Private helpers

  defp validate_session_id(%{session_id: session_id})
       when is_binary(session_id) and session_id != "" do
    {:ok, session_id}
  end

  defp validate_session_id(%{session_id: ""}),
    do: {:error, Error.new(:validation_error, "session_id cannot be empty")}

  defp validate_session_id(_),
    do: {:error, Error.new(:validation_error, "session_id is required")}

  defp generate_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> then(&"run_#{&1}")
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

  defp parse_optional_datetime(nil), do: nil

  defp parse_optional_datetime(datetime) when is_binary(datetime) do
    case DateTime.from_iso8601(datetime) do
      {:ok, dt, _} -> dt
      {:error, _} -> nil
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(datetime), do: DateTime.to_iso8601(datetime)
end
