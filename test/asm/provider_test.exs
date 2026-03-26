defmodule ASM.ProviderTest do
  use ASM.TestCase

  alias ASM.Provider

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

  test "example_support!/1 accepts a resolved provider struct" do
    provider = Provider.resolve!(:amp)
    support = Provider.example_support!(provider)

    assert support.cli_command == "amp"
    assert support.install_hint =~ "@sourcegraph/amp"
  end
end
