defmodule ASM.ProviderBackend.SdkUnavailableError do
  @moduledoc """
  Stable cause category for explicit SDK-lane requests that cannot run.

  The public ASM boundary still returns `%ASM.Error{}` for runtime/config
  failures. This struct is stored in `ASM.Error.cause` so tests and callers can
  distinguish SDK unavailability from unrelated configuration failures without
  matching message text.
  """

  defexception [:provider, :lane, :runtime, :execution_mode, :reason, :message]

  @type t :: %__MODULE__{
          provider: atom() | nil,
          lane: atom() | nil,
          runtime: module() | nil,
          execution_mode: atom() | nil,
          reason: atom(),
          message: String.t()
        }

  @impl true
  def exception(opts) do
    provider = Keyword.get(opts, :provider)
    lane = Keyword.get(opts, :lane, :sdk)
    runtime = Keyword.get(opts, :runtime)
    execution_mode = Keyword.get(opts, :execution_mode)
    reason = Keyword.get(opts, :reason, :sdk_unavailable)

    message =
      Keyword.get_lazy(opts, :message, fn ->
        case reason do
          :unsupported_execution_mode ->
            "sdk lane is unavailable for #{inspect(execution_mode)} execution"

          :provider_runtime_profile ->
            "sdk lane is unavailable while a provider runtime profile is active"

          _ ->
            "sdk lane requested but runtime kit is unavailable"
        end
      end)

    %__MODULE__{
      provider: provider,
      lane: lane,
      runtime: runtime,
      execution_mode: execution_mode,
      reason: reason,
      message: message
    }
  end
end
