defmodule ASM.Extensions.Provider do
  @moduledoc """
  Boundary root reserved for provider add-on extension domains.

  Provider-native Phase 2B namespaces now live under
  `ASM.Extensions.ProviderSDK`.
  """

  use Boundary, deps: [ASM], exports: []
end
