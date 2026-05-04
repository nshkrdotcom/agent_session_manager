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

  test "non-codex governed core backend cannot fall through to standalone auth" do
    execution_config = %Execution.Config{
      execution_mode: :local,
      transport_call_timeout_ms: 5_000,
      execution_environment: %Environment{}
    }

    with_env(provider_env(), fn ->
      config = %{
        provider: Provider.resolve!(:claude),
        prompt: "hello",
        provider_opts: [model: "sonnet"],
        execution_config: execution_config,
        metadata: governed_runtime_metadata(:claude)
      }

      assert {:error, error} = Core.start_run(config)
      assert error.kind == :config_invalid
      assert error.message =~ "requires verified provider-auth materialization"
      assert error.message =~ "standalone env"
    end)
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
      native_auth_assertion_ref: "codex-native-auth://assertion/core",
      target_ref: "execution-target://codex/core-target",
      operation_policy_ref: "operation-policy://codex/core"
    )
    |> ASM.RuntimeAuth.to_metadata()
  end

  defp governed_runtime_metadata(provider) when is_atom(provider) do
    "core-governed-runtime-#{provider}"
    |> ASM.RuntimeAuth.new!(provider,
      runtime_auth_mode: :governed,
      runtime_auth_scope: :governed,
      execution_context_ref: "asm-execution-context://governed/core-#{provider}",
      connector_instance_ref: "jido-connector-instance://#{provider}/core-instance",
      connector_binding_ref: "jido-connector-binding://#{provider}/core-binding",
      provider_account_ref: "provider-account://#{provider}/core-account",
      authority_ref: "citadel-authority://decision/core-#{provider}",
      credential_lease_ref: "jido-credential-lease://lease/core-#{provider}",
      native_auth_assertion_ref: "native-auth://assertion/core-#{provider}",
      target_ref: "execution-target://#{provider}/core-target",
      operation_policy_ref: "operation-policy://#{provider}/core"
    )
    |> ASM.RuntimeAuth.to_metadata()
  end

  defp with_env(env, fun) when is_map(env) and is_function(fun, 0) do
    saved = Map.new(env, fn {key, _value} -> {key, System.get_env(key)} end)

    try do
      Enum.each(env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      fun.()
    after
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp provider_env do
    [
      "ANTHROPIC_API_KEY",
      "ANTHROPIC_AUTH_TOKEN",
      "ANTHROPIC_BASE_URL",
      "ASM_CLAUDE_MODEL",
      "CLAUDE_CLI_PATH",
      "CLAUDE_CODE_OAUTH_TOKEN",
      "CLAUDE_CONFIG_DIR",
      "CLAUDE_HOME",
      "CLAUDE_MODEL"
    ]
    |> Map.new(&{&1, nil})
  end
end
