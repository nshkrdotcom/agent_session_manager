defmodule ASM.JidoHarness.CodexAdapter do
  @moduledoc """
  Harness adapter wrapper for running Codex sessions through ASM.
  """

  use ASM.JidoHarness.ProviderAdapter, provider: :codex
end
