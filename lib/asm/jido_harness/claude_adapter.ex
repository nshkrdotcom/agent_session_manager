defmodule ASM.JidoHarness.ClaudeAdapter do
  @moduledoc """
  Harness adapter wrapper for running Claude sessions through ASM.
  """

  use ASM.JidoHarness.ProviderAdapter, provider: :claude
end
