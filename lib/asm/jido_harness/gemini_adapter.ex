defmodule ASM.JidoHarness.GeminiAdapter do
  @moduledoc """
  Harness adapter wrapper for running Gemini sessions through ASM.
  """

  use ASM.JidoHarness.ProviderAdapter, provider: :gemini
end
