defmodule ASM.JidoHarness.AmpAdapter do
  @moduledoc """
  Harness adapter wrapper for running Amp sessions through ASM.
  """

  use ASM.JidoHarness.ProviderAdapter, provider: :amp
end
