defmodule ASM.JidoHarness.ShellAdapter do
  @moduledoc """
  Harness adapter wrapper for running shell sessions through ASM.
  """

  use ASM.JidoHarness.ProviderAdapter, provider: :shell
end
