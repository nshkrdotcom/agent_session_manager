defmodule ASM.RuntimeAuthCodexMaterializationTest do
  use ASM.TestCase

  alias ASM.Options
  alias ASM.RuntimeAuth
  alias ASM.RuntimeAuth.CodexMaterialization
  alias CliSubprocessCore.ExecutionSurface

  setup do
    saved = capture_codex_env()
    clear_codex_env()

    on_exit(fn -> restore_env(saved) end)

    :ok
  end

  test "governed Codex materialization carries only verified command cwd env and config root" do
    metadata = governed_metadata()

    assert {:ok, %CodexMaterialization{} = materialization} =
             CodexMaterialization.authorize_config(
               config(metadata, materialized_runtime()),
               []
             )

    assert materialization.command == "/materialized/bin/codex"
    assert materialization.cwd == "/workspace/project"
    assert materialization.env == %{"CODEX_HOME" => "/materialized/codex-home"}
    assert materialization.clear_env? == true

    evidence = CodexMaterialization.redacted_evidence(materialization)
    assert evidence.command == :redacted_materialized_command
    assert evidence.cwd == :redacted_materialized_cwd
    assert evidence.config_root == :redacted_materialized_config_root
    assert evidence.env_keys == ["CODEX_HOME"]
    refute String.contains?(inspect(evidence), "/materialized/bin/codex")
  end

  test "governed Codex strict mode rejects provider option smuggling" do
    metadata = governed_metadata()

    for {key, value} <- [
          cli_path: "/attacker/bin/codex",
          cwd: "/attacker/work",
          env: %{"CODEX_API_KEY" => "secret"},
          config_root: "/attacker/codex-home",
          config_values: ["model_provider=\"attacker\""],
          api_key: "secret",
          base_url: "https://attacker.example.com/v1",
          provider_backend: :oss
        ] do
      assert {:error, error} =
               CodexMaterialization.authorize_config(
                 config(metadata, materialized_runtime()),
                 [{key, value}]
               )

      assert error.kind == :config_invalid
      assert String.contains?(error.message, "governed Codex strict mode rejects")
    end
  end

  test "governed Codex strict mode accepts finalized empty provider defaults" do
    metadata = governed_metadata()
    assert {:ok, provider_opts} = Options.finalize_provider_opts(:codex, [])

    assert {:ok, %CodexMaterialization{}} =
             CodexMaterialization.authorize_config(
               config(metadata, materialized_runtime()),
               provider_opts
             )
  end

  test "governed Codex strict mode rejects transport and backend override smuggling" do
    metadata = governed_metadata()
    execution_surface = %{transport_options: [cwd: "/attacker"]}

    assert {:error, transport_error} =
             CodexMaterialization.authorize_config(
               config(metadata, materialized_runtime(), execution_surface: execution_surface),
               []
             )

    assert String.contains?(transport_error.message, "materialized runtime override")

    assert {:error, backend_error} =
             CodexMaterialization.authorize_config(
               config(metadata, materialized_runtime(),
                 backend_opts: [connect_opts: [process_env: %{"CODEX_HOME" => "/attacker"}]]
               ),
               []
             )

    assert String.contains?(backend_error.message, "materialized runtime override")
  end

  test "governed Codex strict mode rejects unmanaged ambient provider auth env" do
    System.put_env("CODEX_API_KEY", "ambient-secret")

    assert {:error, error} =
             CodexMaterialization.authorize_config(
               config(governed_metadata(), materialized_runtime()),
               []
             )

    assert error.kind == :config_invalid
    assert String.contains?(error.message, "unmanaged ambient provider auth")
    assert error.cause.env_keys == ["CODEX_API_KEY"]
  end

  test "governed Codex strict mode rejects missing materialization" do
    assert {:error, error} =
             CodexMaterialization.authorize_config(
               Map.delete(
                 config(governed_metadata(), materialized_runtime()),
                 :codex_materialized_runtime
               ),
               []
             )

    assert error.kind == :config_invalid
    assert String.contains?(error.message, "requires a materialized runtime")
  end

  test "standalone Codex compatibility does not require governed materialization" do
    assert {:ok, runtime_auth} = RuntimeAuth.new("standalone-materialization", :codex)
    metadata = RuntimeAuth.to_metadata(runtime_auth)

    assert {:ok, nil} =
             CodexMaterialization.authorize_config(%{metadata: metadata},
               cwd: "/standalone/work",
               env: %{"CODEX_API_KEY" => "standalone-local"}
             )
  end

  defp governed_metadata do
    "governed-materialization"
    |> RuntimeAuth.new!(:codex,
      runtime_auth_mode: :governed,
      runtime_auth_scope: :governed,
      execution_context_ref: "asm-execution-context://governed/materialization",
      connector_instance_ref: "jido-connector-instance://codex/instance-1",
      connector_binding_ref: "jido-connector-binding://codex/binding-1",
      provider_account_ref: "provider-account://codex/account-1",
      authority_ref: "citadel-authority://decision/1",
      credential_lease_ref: "jido-credential-lease://lease/1",
      native_auth_assertion_ref: "codex-native-auth://assertion/1",
      target_ref: "execution-target://codex/target-1",
      operation_policy_ref: "operation-policy://codex/policy-1"
    )
    |> RuntimeAuth.to_metadata()
  end

  defp materialized_runtime do
    %{
      source: :verified_materializer,
      command: "/materialized/bin/codex",
      cwd: "/workspace/project",
      config_root: "/materialized/codex-home",
      env: %{"CODEX_HOME" => "/materialized/codex-home"},
      clear_env?: true,
      target_auth_posture: :materialize_on_attach,
      native_auth_assertion: %{
        introspection_level: :auth_file_metadata,
        limits: %{secrets: :redacted, token_values: :not_read},
        redacted?: true
      }
    }
  end

  defp config(metadata, materialized_runtime, opts \\ []) do
    %{
      metadata: metadata,
      execution_surface: Keyword.get(opts, :execution_surface, %ExecutionSurface{}),
      backend_opts: Keyword.get(opts, :backend_opts, []),
      codex_materialized_runtime: materialized_runtime
    }
  end

  defp capture_codex_env do
    Map.new(codex_env_keys(), &{&1, System.get_env(&1)})
  end

  defp clear_codex_env do
    Enum.each(codex_env_keys(), &System.delete_env/1)
  end

  defp restore_env(saved) do
    Enum.each(saved, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp codex_env_keys do
    ["CODEX_API_KEY", "OPENAI_API_KEY", "CODEX_HOME", "OPENAI_BASE_URL"]
  end
end
