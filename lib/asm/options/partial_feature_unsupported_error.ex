defmodule ASM.Options.PartialFeatureUnsupportedError do
  @moduledoc """
  Returned when a partial/discovery feature is used as if it were common.
  """

  defexception [:key, :provider, :mode, :feature, :message]

  @type t :: %__MODULE__{
          key: atom(),
          provider: atom() | nil,
          mode: atom() | nil,
          feature: atom() | nil,
          message: String.t()
        }

  @impl true
  def exception(opts) do
    key = Keyword.fetch!(opts, :key)
    provider = Keyword.get(opts, :provider)
    mode = Keyword.get(opts, :mode)
    feature = Keyword.get(opts, :feature)

    message =
      Keyword.get_lazy(opts, :message, fn ->
        "option #{inspect(key)} belongs to partial feature #{inspect(feature)} and is not admitted as all-provider common ASM behavior"
      end)

    %__MODULE__{key: key, provider: provider, mode: mode, feature: feature, message: message}
  end
end
