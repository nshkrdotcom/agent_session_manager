defmodule ASM.Error do
  @moduledoc """
  Canonical runtime error type for ASM.
  """

  @enforce_keys [:kind, :domain, :message]
  defexception [:kind, :domain, :message, :cause, :provider, :exit_code, :retryable]

  @type domain ::
          :transport | :parser | :provider | :approval | :guardrail | :tool | :runtime | :config

  @type kind ::
          :cli_not_found
          | :connection_failed
          | :timeout
          | :parse_error
          | :json_decode_error
          | :auth_error
          | :rate_limit
          | :buffer_overflow
          | :transport_error
          | :transport_busy
          | :queue_full
          | :at_capacity
          | :user_cancelled
          | :approval_denied
          | :guardrail_blocked
          | :tool_failed
          | :config_invalid
          | :unknown

  @type t :: %__MODULE__{
          kind: kind(),
          domain: domain(),
          message: String.t(),
          cause: term() | nil,
          provider: atom() | nil,
          exit_code: integer() | nil,
          retryable: boolean() | nil
        }

  @spec new(kind(), domain(), String.t(), keyword()) :: t()
  def new(kind, domain, message, opts \\ []) when is_binary(message) do
    %__MODULE__{
      kind: kind,
      domain: domain,
      message: message,
      cause: Keyword.get(opts, :cause),
      provider: Keyword.get(opts, :provider),
      exit_code: Keyword.get(opts, :exit_code),
      retryable: Keyword.get(opts, :retryable)
    }
  end

  @impl true
  def exception(opts) when is_list(opts) do
    kind = Keyword.get(opts, :kind, :unknown)
    domain = Keyword.get(opts, :domain, :runtime)
    message = Keyword.get(opts, :message, "ASM runtime error")

    new(kind, domain, message,
      cause: Keyword.get(opts, :cause),
      provider: Keyword.get(opts, :provider),
      exit_code: Keyword.get(opts, :exit_code),
      retryable: Keyword.get(opts, :retryable)
    )
  end

  @impl true
  def message(%__MODULE__{domain: domain, kind: kind, message: msg}) do
    "[#{domain}/#{kind}] #{msg}"
  end
end
