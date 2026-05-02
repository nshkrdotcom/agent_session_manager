defmodule ASM.ProviderBackend.CoreTest do
  use ASM.TestCase

  alias ASM.{Execution, Provider}
  alias ASM.Execution.Environment
  alias ASM.ProviderBackend.Core

  test "start_run/1 rejects explicit approval_posture :none before runtime start" do
    execution_config =
      %Execution.Config{
        execution_mode: :local,
        transport_call_timeout_ms: 5_000,
        execution_environment: %Environment{approval_posture: :none}
      }

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

  test "codex core backend rejects governed runs without materialized runtime" do
    execution_config = %Execution.Config{
      execution_mode: :local,
      transport_call_timeout_ms: 5_000,
      execution_environment: %Environment{}
    }

    config = %{
      provider: Provider.resolve!(:codex),
      prompt: "hello",
      provider_opts: [model: "gpt-5.4"],
      execution_config: execution_config,
      metadata: governed_runtime_metadata()
    }

    assert {:error, error} = Core.start_run(config)
    assert error.kind == :config_invalid
    assert error.message =~ "requires a materialized runtime"
  end

  defp governed_runtime_metadata do
    "core-governed-runtime"
    |> ASM.RuntimeAuth.new!(:codex,
      runtime_auth_mode: :governed,
      runtime_auth_scope: :governed,
      execution_context_ref: "asm-execution-context://governed/core",
      connector_instance_ref: "jido-connector-instance://codex/core-instance",
      connector_binding_ref: "jido-connector-binding://codex/core-binding",
      provider_account_ref: "provider-account://codex/core-account",
      authority_ref: "citadel-authority://decision/core",
      credential_lease_ref: "jido-credential-lease://lease/core",
      native_auth_assertion_ref: "codex-native-auth://assertion/core"
    )
    |> ASM.RuntimeAuth.to_metadata()
  end
end
