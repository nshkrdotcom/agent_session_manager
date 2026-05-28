defmodule ASM.ProviderAntigravityTest do
  use ASM.TestCase

  alias ASM.{Cost, Options, Permission, Provider, ProviderFeatures, ProviderRegistry, RuntimeAuth}
  alias ASM.Schema.ProviderOptions, as: ProviderOptionsSchema

  test "Antigravity resolves as a first-party provider with complete metadata" do
    assert :antigravity in Provider.supported_providers()
    assert {:ok, provider} = Provider.resolve("antigravity")

    assert provider.name == :antigravity
    assert provider.display_name == "Antigravity CLI"
    assert provider.core_profile == CliSubprocessCore.ProviderProfiles.Antigravity
    assert provider.sdk_runtime == :"Elixir.AntigravityCliSdk.Runtime.CLI"
    assert provider.options_schema == ASM.Options.Antigravity.schema()
    assert provider.profile.max_concurrent_runs == 1
    assert provider.profile.max_queued_runs == 10

    support = Provider.example_support!(provider)

    assert support.cli_command == "agy"
    assert support.cli_path_env == "ANTIGRAVITY_CLI_PATH"
    assert support.model_env == "ASM_ANTIGRAVITY_MODEL"
    assert support.sdk_app == :antigravity_cli_sdk
    assert support.sdk_repo_dir == "antigravity_cli_sdk"
    assert support.sdk_root_env == "ANTIGRAVITY_CLI_SDK_ROOT"
    assert support.sdk_cli_env == "ANTIGRAVITY_CLI_PATH"
  end

  test "Antigravity permission modes use explicit provider-native terms" do
    assert {:ok, %{normalized: :default, native: :default}} =
             Permission.normalize(:antigravity, :default)

    assert {:ok, %{normalized: :bypass, native: :bypass}} =
             Permission.normalize(:antigravity, :bypass)

    assert {:ok, %{normalized: :bypass, native: :bypass}} =
             Permission.normalize(:antigravity, "dangerously_skip_permissions")

    assert ProviderFeatures.permission_mode!(:antigravity, :bypass).cli_args == [
             "--dangerously-skip-permissions"
           ]
  end

  test "Antigravity option schema validates native agy controls" do
    schema = Provider.resolve!(:antigravity).options_schema

    assert {:ok, validated} =
             Options.validate(
               [
                 provider: :antigravity,
                 model: "default",
                 permission_mode: :bypass,
                 sandbox: true,
                 dangerously_skip_permissions: true,
                 conversation: "agy-conversation-1",
                 continue: true,
                 add_dirs: ["/workspace/one", "/workspace/two"],
                 print_timeout: "30s",
                 log_file: "/tmp/agy.log"
               ],
               schema
             )

    assert validated[:provider] == :antigravity
    assert validated[:provider_permission_mode] == :bypass
    assert validated[:sandbox] == true
    assert validated[:dangerously_skip_permissions] == true
    assert validated[:conversation] == "agy-conversation-1"
    assert validated[:continue] == true
    assert validated[:add_dirs] == ["/workspace/one", "/workspace/two"]
    assert validated[:print_timeout] == "30s"
    assert validated[:log_file] == "/tmp/agy.log"
    assert {:ok, ^validated} = ProviderOptionsSchema.validate(validated)
  end

  test "Antigravity model payload is attached without dynamic provider atoms" do
    schema = Provider.resolve!(:antigravity).options_schema

    assert {:ok, validated} = Options.validate([provider: :antigravity], schema)
    assert {:ok, finalized} = Options.finalize_provider_opts(:antigravity, validated)

    payload = Keyword.fetch!(finalized, :model_payload)

    assert payload.provider == :antigravity
    assert payload.resolved_model == "default"
    refute Keyword.has_key?(finalized, :model)
  end

  test "Antigravity runtime auth env keys are explicit and inspectable" do
    assert RuntimeAuth.provider_auth_env_keys(:antigravity) == [
             "ANTIGRAVITY_API_KEY",
             "ANTIGRAVITY_CLI_PATH",
             "ASM_ANTIGRAVITY_MODEL",
             "ANTIGRAVITY_MODEL",
             "ANTIGRAVITY_LOG_FILE"
           ]
  end

  test "Antigravity cost defaults and lane metadata are available" do
    assert Cost.Models.lookup(:antigravity, nil) == %{
             input_rate: 0.000002,
             output_rate: 0.000008
           }

    assert Cost.Models.lookup(:antigravity, "default") == %{
             input_rate: 0.000002,
             output_rate: 0.000008
           }

    assert {:ok, :antigravity} = ProviderRegistry.core_profile_id(:antigravity)

    assert {:ok, lane} = ProviderRegistry.lane_info(:antigravity, lane: :core)
    assert lane.preferred_lane == :core
    assert lane.backend == ASM.ProviderBackend.Core
  end
end
