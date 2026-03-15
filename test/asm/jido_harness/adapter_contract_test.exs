defmodule ASM.JidoHarness.AdapterContractTest do
  use ExUnit.Case, async: false

  use Jido.Harness.AdapterContract,
    adapter: ASM.JidoHarness.ClaudeAdapter,
    provider: :claude,
    check_run: true,
    run_request: %{prompt: "adapter contract", metadata: %{}},
    run_opts: [driver: ASM.TestSupport.StreamScriptedDriver]
end
