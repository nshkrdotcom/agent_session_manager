defmodule ASM.ProviderBackend.CoreTest do
  use ASM.TestCase

  alias ASM.{Execution, Provider}
  alias ASM.ProviderBackend.Core

  test "start_run/1 rejects explicit approval_posture :none before runtime start" do
    execution_config =
      %Execution.Config{
        execution_mode: :local,
        transport_call_timeout_ms: 5_000
      }
      |> Map.put(:approval_posture, :none)

    config = %{
      provider: Provider.resolve!(:claude),
      prompt: "hello",
      provider_opts: [],
      execution_config: execution_config
    }

    assert {:error, error} = Core.start_run(config)
    assert error.kind == :config_invalid
    assert error.domain == :config
    assert error.message =~ "approval_posture"
    assert error.message =~ ":none"
  end
end
