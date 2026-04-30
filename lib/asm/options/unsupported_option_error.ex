defmodule ASM.Options.UnsupportedOptionError do
  @moduledoc """
  Returned when a strict ASM common preflight receives an unsupported option.
  """

  defexception [:key, :provider, :mode, :reason, :message]

  @type t :: %__MODULE__{
          key: atom() | term(),
          provider: atom() | nil,
          mode: atom() | nil,
          reason: atom() | term(),
          message: String.t()
        }

  @impl true
  def exception(opts) do
    key = Keyword.get(opts, :key)
    provider = Keyword.get(opts, :provider)
    mode = Keyword.get(opts, :mode)
    reason = Keyword.get(opts, :reason, :unsupported)

    message =
      Keyword.get_lazy(opts, :message, fn ->
        "unsupported ASM option #{inspect(key)} for provider #{inspect(provider)} in #{inspect(mode)} mode"
      end)

    %__MODULE__{key: key, provider: provider, mode: mode, reason: reason, message: message}
  end
end
