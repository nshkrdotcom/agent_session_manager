defmodule ASM.Options.ProviderNativeOptionError do
  @moduledoc """
  Returned when provider-native behavior is passed through the generic ASM path.
  """

  defexception [:key, :provider, :mode, :reason, :migration, :message]

  @type t :: %__MODULE__{
          key: atom(),
          provider: atom() | nil,
          mode: atom() | nil,
          reason: atom(),
          migration: String.t() | nil,
          message: String.t()
        }

  @impl true
  def exception(opts) do
    key = Keyword.fetch!(opts, :key)
    provider = Keyword.get(opts, :provider)
    mode = Keyword.get(opts, :mode)
    reason = Keyword.get(opts, :reason, :provider_native)
    migration = Keyword.get(opts, :migration)

    message =
      Keyword.get_lazy(opts, :message, fn ->
        "option #{inspect(key)} is provider-native or an unsafe escape hatch and is not part of ASM's strict common contract"
      end)

    %__MODULE__{
      key: key,
      provider: provider,
      mode: mode,
      reason: reason,
      migration: migration,
      message: message
    }
  end
end
