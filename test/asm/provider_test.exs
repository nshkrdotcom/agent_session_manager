defmodule ASM.ProviderTest do
  use ASM.TestCase

  alias ASM.Provider
  alias ASM.Provider.Profile

  test "example_support!/1 returns the canonical example metadata" do
    support = Provider.example_support!(:codex)

    assert support.cli_command == "codex"
    assert support.cli_path_env == "CODEX_PATH"
    assert support.model_env == "ASM_CODEX_MODEL"
    assert support.sdk_app == :codex_sdk
    assert support.sdk_repo_dir == "codex_sdk"
    assert support.sdk_root_env == "CODEX_SDK_ROOT"
    assert support.sdk_cli_env == "CODEX_PATH"
  end

  test "cursor resolves as the fifth provider with core and sdk lanes" do
    assert :cursor in Provider.supported_providers()
    assert {:ok, provider} = Provider.resolve("cursor")

    assert provider.name == :cursor
    assert provider.display_name == "Cursor Agent CLI"
    assert provider.core_profile == CliSubprocessCore.ProviderProfiles.Cursor
    assert provider.sdk_runtime == CursorCliSdk.Runtime.CLI
    assert provider.options_schema == ASM.Options.Cursor.schema()

    support = Provider.example_support!(provider)

    assert support.cli_command == "agent"
    assert support.cli_path_env == "CURSOR_CLI_PATH"
    assert support.model_env == "ASM_CURSOR_MODEL"
    assert support.sdk_app == :cursor_cli_sdk
    assert support.sdk_repo_dir == "cursor_cli_sdk"
    assert support.sdk_root_env == "CURSOR_CLI_SDK_ROOT"
    assert support.sdk_cli_env == "CURSOR_CLI_PATH"
  end

  test "example_support!/1 accepts a resolved provider struct" do
    provider = Provider.resolve!(:amp)
    support = Provider.example_support!(provider)

    assert support.cli_command == "amp"
    assert String.contains?(support.install_hint, "@sourcegraph/amp")
  end

  test "resolve/1 accepts bounded provider strings and rejects unknown strings" do
    assert {:ok, provider} = Provider.resolve("codex_exec")
    assert provider.name == :codex

    assert {:error, error} = Provider.resolve("unknown-provider")
    assert error.kind == :config_invalid
    assert String.contains?(error.message, "Unknown provider")
  end

  test "Google coding-agent support is Antigravity-only" do
    assert :antigravity in Provider.supported_providers()
    refute :gemini in Provider.supported_providers()
    assert {:ok, %{name: :antigravity}} = Provider.resolve(:antigravity)
    assert {:error, error} = Provider.resolve(:gemini)
    assert error.kind == :config_invalid
  end

  test "provider profiles use the schema-backed closed boundary" do
    assert {:ok, %Profile{max_concurrent_runs: 2, max_queued_runs: 4}} =
             Profile.new(max_concurrent_runs: 2, max_queued_runs: 4)

    assert {:error, error} = Profile.new(max_concurrent_runs: 1, future_flag: true)
    assert String.contains?(error.message, "future_flag")
  end
end
