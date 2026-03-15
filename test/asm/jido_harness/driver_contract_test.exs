defmodule ASM.JidoHarness.DriverContractTest do
  use ExUnit.Case, async: false

  use Jido.Harness.RuntimeDriverContract,
    driver: ASM.JidoHarness.Driver,
    start_session_opts: [provider: :claude],
    check_stream_run: true,
    check_run: true,
    run_request: %{prompt: "contract test", metadata: %{}},
    run_opts: [driver: ASM.TestSupport.StreamScriptedDriver]
end
