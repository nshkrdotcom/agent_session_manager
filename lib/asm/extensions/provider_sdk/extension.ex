defmodule ASM.Extensions.ProviderSDK.Extension do
  @moduledoc """
  Metadata contract for an optional provider-native ASM extension namespace.
  """

  @enforce_keys [:id, :provider, :namespace, :sdk_app, :sdk_module, :description]
  defstruct [
    :id,
    :provider,
    :namespace,
    :sdk_app,
    :sdk_module,
    :description,
    sdk_available?: false,
    native_capabilities: [],
    native_surface_modules: []
  ]

  @type t :: %__MODULE__{
          id: atom(),
          provider: ASM.Provider.provider_name(),
          namespace: module(),
          sdk_app: atom(),
          sdk_module: module(),
          description: String.t(),
          sdk_available?: boolean(),
          native_capabilities: [atom()],
          native_surface_modules: [module()]
        }

  @spec new!(keyword()) :: t()
  def new!(attrs) when is_list(attrs) do
    struct!(__MODULE__, attrs)
  end
end
