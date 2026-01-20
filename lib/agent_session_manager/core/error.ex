defmodule AgentSessionManager.Core.Error do
  @moduledoc """
  Normalized error taxonomy for Agent Session Manager.

  Provides machine-readable error codes organized into categories,
  with support for provider-specific error details and context.

  ## Error Categories

  - **Validation**: Input and format validation errors
  - **Resource**: Not found, already exists, duplicates
  - **Provider**: External AI provider errors (rate limits, timeouts, auth)
  - **Storage**: Persistence layer errors
  - **Runtime**: Timeouts, cancellations, internal errors
  - **Tool**: Tool execution errors

  ## Usage

      # Create a basic error
      error = Error.new(:validation_error, "Invalid input provided")

      # Create with details and context
      error = Error.new(:session_not_found, "Session not found",
        details: %{session_id: "session-123"},
        context: %{operation: "get"}
      )

      # Wrap a provider error
      error = Error.new(:provider_rate_limited, "Rate limited",
        provider_error: %{status_code: 429, body: "Too many requests"}
      )

      # Check if error is retryable
      Error.retryable?(error) # => true

      # Raise an error
      raise Error, code: :validation_error, message: "Invalid input"

  """

  # Validation errors
  @validation_codes [
    :validation_error,
    :invalid_input,
    :missing_required_field,
    :invalid_format
  ]

  # State/Status errors
  @state_codes [
    :invalid_status,
    :invalid_transition,
    :invalid_event_type,
    :invalid_capability_type,
    :missing_required_capability
  ]

  # Resource errors
  @resource_codes [
    :not_found,
    :session_not_found,
    :run_not_found,
    :capability_not_found,
    :already_exists,
    :duplicate_capability
  ]

  # Provider errors
  @provider_codes [
    :provider_error,
    :provider_unavailable,
    :provider_rate_limited,
    :provider_timeout,
    :provider_authentication_failed,
    :provider_quota_exceeded
  ]

  # Storage errors
  @storage_codes [
    :storage_error,
    :storage_connection_failed,
    :storage_write_failed,
    :storage_read_failed
  ]

  # Runtime errors
  @runtime_codes [
    :timeout,
    :cancelled,
    :internal_error,
    :unknown_error
  ]

  # Tool errors
  @tool_codes [
    :tool_error,
    :tool_not_found,
    :tool_execution_failed,
    :tool_permission_denied
  ]

  @all_codes @validation_codes ++
               @state_codes ++
               @resource_codes ++
               @provider_codes ++
               @storage_codes ++
               @runtime_codes ++
               @tool_codes

  @retryable_codes [
    :provider_timeout,
    :provider_rate_limited,
    :provider_unavailable,
    :storage_connection_failed,
    :timeout
  ]

  @default_messages %{
    validation_error: "Validation error occurred",
    invalid_input: "Invalid input provided",
    missing_required_field: "Required field is missing",
    invalid_format: "Invalid format",
    invalid_status: "Invalid status value",
    invalid_transition: "Invalid state transition",
    invalid_event_type: "Invalid event type",
    invalid_capability_type: "Invalid capability type",
    missing_required_capability: "Required capability is missing",
    not_found: "Resource not found",
    session_not_found: "Session not found",
    run_not_found: "Run not found",
    capability_not_found: "Capability not found",
    already_exists: "Resource already exists",
    duplicate_capability: "Capability with this name already exists",
    provider_error: "Provider error occurred",
    provider_unavailable: "Provider is unavailable",
    provider_rate_limited: "Provider rate limit exceeded",
    provider_timeout: "Provider request timed out",
    provider_authentication_failed: "Provider authentication failed",
    provider_quota_exceeded: "Provider quota exceeded",
    storage_error: "Storage error occurred",
    storage_connection_failed: "Storage connection failed",
    storage_write_failed: "Storage write operation failed",
    storage_read_failed: "Storage read operation failed",
    timeout: "Operation timed out",
    cancelled: "Operation was cancelled",
    internal_error: "Internal error occurred",
    unknown_error: "An unknown error occurred",
    tool_error: "Tool error occurred",
    tool_not_found: "Tool not found",
    tool_execution_failed: "Tool execution failed",
    tool_permission_denied: "Tool permission denied"
  }

  @type error_code ::
          :validation_error
          | :invalid_input
          | :missing_required_field
          | :invalid_format
          | :invalid_status
          | :invalid_transition
          | :invalid_event_type
          | :invalid_capability_type
          | :missing_required_capability
          | :not_found
          | :session_not_found
          | :run_not_found
          | :capability_not_found
          | :already_exists
          | :duplicate_capability
          | :provider_error
          | :provider_unavailable
          | :provider_rate_limited
          | :provider_timeout
          | :provider_authentication_failed
          | :provider_quota_exceeded
          | :storage_error
          | :storage_connection_failed
          | :storage_write_failed
          | :storage_read_failed
          | :timeout
          | :cancelled
          | :internal_error
          | :unknown_error
          | :tool_error
          | :tool_not_found
          | :tool_execution_failed
          | :tool_permission_denied

  @type error_category ::
          :validation | :state | :resource | :provider | :storage | :runtime | :tool | :unknown

  @type t :: %__MODULE__{
          code: error_code(),
          message: String.t(),
          details: map(),
          provider_error: map() | nil,
          stacktrace: list() | nil,
          timestamp: DateTime.t(),
          context: map()
        }

  # Use defexception to properly implement the Exception behaviour
  # This automatically adds __exception__: true and implements exception/1 and message/1
  defexception [
    :code,
    :message,
    :provider_error,
    :stacktrace,
    details: %{},
    context: %{},
    timestamp: nil
  ]

  @impl Exception
  def exception(opts) when is_list(opts) do
    code = Keyword.get(opts, :code, :unknown_error)
    message = Keyword.get(opts, :message, default_message(code))

    %__MODULE__{
      code: code,
      message: message,
      details: Keyword.get(opts, :details, %{}),
      provider_error: Keyword.get(opts, :provider_error),
      stacktrace: Keyword.get(opts, :stacktrace),
      context: Keyword.get(opts, :context, %{}),
      timestamp: DateTime.utc_now()
    }
  end

  @impl Exception
  def message(%__MODULE__{code: code, message: msg}) do
    "[#{code}] #{msg}"
  end

  @doc """
  Creates a new error with the given code and an optional message.

  ## Examples

      iex> Error.new(:validation_error, "Invalid input")
      %Error{code: :validation_error, message: "Invalid input", ...}

      iex> Error.new(:validation_error)
      %Error{code: :validation_error, message: "Validation error occurred", ...}

  """
  @spec new(error_code()) :: t()
  def new(code) when is_atom(code) do
    new(code, default_message(code), [])
  end

  @spec new(error_code(), String.t()) :: t()
  def new(code, message) when is_atom(code) and is_binary(message) do
    new(code, message, [])
  end

  @spec new(error_code(), String.t(), keyword()) :: t()
  def new(code, message, opts) when is_atom(code) and is_binary(message) and is_list(opts) do
    %__MODULE__{
      code: code,
      message: message,
      details: Keyword.get(opts, :details, %{}),
      provider_error: Keyword.get(opts, :provider_error),
      stacktrace: Keyword.get(opts, :stacktrace),
      context: Keyword.get(opts, :context, %{}),
      timestamp: DateTime.utc_now()
    }
  end

  @doc """
  Wraps an existing exception into an Error struct.

  ## Examples

      iex> Error.wrap(:internal_error, RuntimeError.exception("Something broke"))
      %Error{code: :internal_error, ...}

  """
  @spec wrap(error_code(), Exception.t(), keyword()) :: t()
  def wrap(code, exception, opts \\ [])

  def wrap(code, %{__exception__: true, message: msg} = exception, opts) do
    custom_message = Keyword.get(opts, :message)
    final_message = custom_message || msg

    details =
      Keyword.get(opts, :details, %{})
      |> Map.put(:original_exception, exception.__struct__)
      |> then(fn d ->
        if custom_message, do: Map.put(d, :original_message, msg), else: d
      end)

    new(code, final_message, Keyword.put(opts, :details, details))
  end

  @doc """
  Checks if the given error code is valid.
  """
  @spec valid_code?(atom()) :: boolean()
  def valid_code?(code) when is_atom(code), do: code in @all_codes
  def valid_code?(_), do: false

  @doc """
  Returns all valid error codes.
  """
  @spec all_codes() :: [error_code()]
  def all_codes, do: @all_codes

  @doc """
  Returns validation error codes.
  """
  @spec validation_codes() :: [error_code()]
  def validation_codes, do: @validation_codes

  @doc """
  Returns provider error codes.
  """
  @spec provider_codes() :: [error_code()]
  def provider_codes, do: @provider_codes

  @doc """
  Returns storage error codes.
  """
  @spec storage_codes() :: [error_code()]
  def storage_codes, do: @storage_codes

  @doc """
  Returns resource error codes.
  """
  @spec resource_codes() :: [error_code()]
  def resource_codes, do: @resource_codes

  @doc """
  Returns runtime error codes.
  """
  @spec runtime_codes() :: [error_code()]
  def runtime_codes, do: @runtime_codes

  @doc """
  Returns tool error codes.
  """
  @spec tool_codes() :: [error_code()]
  def tool_codes, do: @tool_codes

  @doc """
  Returns the category of an error code.
  """
  @spec category(error_code() | atom()) :: error_category()
  def category(code) when code in @validation_codes, do: :validation
  def category(code) when code in @state_codes, do: :state
  def category(code) when code in @resource_codes, do: :resource
  def category(code) when code in @provider_codes, do: :provider
  def category(code) when code in @storage_codes, do: :storage
  def category(code) when code in @runtime_codes, do: :runtime
  def category(code) when code in @tool_codes, do: :tool
  def category(_), do: :unknown

  @doc """
  Checks if an error is retryable.

  Accepts either an error code atom or an Error struct.
  """
  @spec retryable?(error_code() | t()) :: boolean()
  def retryable?(%__MODULE__{code: code}), do: retryable?(code)
  def retryable?(code) when is_atom(code), do: code in @retryable_codes

  @doc """
  Converts an Error to a map suitable for JSON serialization.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = error) do
    %{
      "code" => Atom.to_string(error.code),
      "message" => error.message,
      "details" => stringify_keys(error.details),
      "provider_error" => stringify_provider_error(error.provider_error),
      "stacktrace" => format_stacktrace(error.stacktrace),
      "context" => stringify_keys(error.context),
      "timestamp" => DateTime.to_iso8601(error.timestamp)
    }
  end

  @doc """
  Reconstructs an Error from a map.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, t()}
  def from_map(map) when is_map(map) do
    with {:ok, code} <- parse_code(map["code"]),
         {:ok, message} <- parse_message(map["message"]),
         {:ok, timestamp} <- parse_timestamp(map["timestamp"]) do
      error = %__MODULE__{
        code: code,
        message: message,
        details: atomize_keys(map["details"] || %{}),
        provider_error: map["provider_error"],
        stacktrace: map["stacktrace"],
        context: atomize_keys(map["context"] || %{}),
        timestamp: timestamp
      }

      {:ok, error}
    end
  end

  def from_map(_), do: {:error, new(:validation_error, "Invalid error map")}

  defp default_message(code), do: Map.get(@default_messages, code, "An error occurred")

  defp parse_code(nil), do: {:error, new(:validation_error, "Missing error code")}

  defp parse_code(code) when is_binary(code) do
    atom = String.to_existing_atom(code)

    if valid_code?(atom) do
      {:ok, atom}
    else
      {:error, new(:validation_error, "Invalid error code: #{code}")}
    end
  rescue
    ArgumentError -> {:error, new(:validation_error, "Invalid error code: #{code}")}
  end

  defp parse_code(_), do: {:error, new(:validation_error, "Invalid error code format")}

  defp parse_message(nil), do: {:error, new(:validation_error, "Missing error message")}
  defp parse_message(message) when is_binary(message), do: {:ok, message}
  defp parse_message(_), do: {:error, new(:validation_error, "Invalid error message format")}

  defp parse_timestamp(nil), do: {:ok, DateTime.utc_now()}

  defp parse_timestamp(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> {:ok, dt}
      {:error, _} -> {:error, new(:validation_error, "Invalid timestamp format")}
    end
  end

  defp parse_timestamp(_), do: {:error, new(:validation_error, "Invalid timestamp format")}

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), stringify_value(v)}
      {k, v} -> {k, stringify_value(v)}
    end)
  end

  defp stringify_keys(other), do: other

  defp stringify_value(v) when is_map(v), do: stringify_keys(v)

  defp stringify_value(v) when is_atom(v) and not is_nil(v) and not is_boolean(v),
    do: Atom.to_string(v)

  defp stringify_value(v), do: v

  defp stringify_provider_error(nil), do: nil
  defp stringify_provider_error(error) when is_map(error), do: stringify_keys(error)

  defp format_stacktrace(nil), do: nil
  defp format_stacktrace(stacktrace), do: stacktrace

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {String.to_atom(k), atomize_value(v)}
      {k, v} -> {k, atomize_value(v)}
    end)
  end

  defp atomize_keys(other), do: other

  defp atomize_value(v) when is_map(v), do: atomize_keys(v)
  defp atomize_value(v), do: v
end

defimpl String.Chars, for: AgentSessionManager.Core.Error do
  def to_string(%{code: code, message: message}) do
    "[#{code}] #{message}"
  end
end
