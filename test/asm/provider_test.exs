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

  test "example_support!/1 accepts a resolved provider struct" do
    provider = Provider.resolve!(:amp)
    support = Provider.example_support!(provider)

    assert support.cli_command == "amp"
    assert support.install_hint =~ "@sourcegraph/amp"
  end

  test "provider profiles use the schema-backed closed boundary" do
    assert {:ok, %Profile{max_concurrent_runs: 2, max_queued_runs: 4}} =
             Profile.new(max_concurrent_runs: 2, max_queued_runs: 4)

    assert {:error, error} = Profile.new(max_concurrent_runs: 1, future_flag: true)
    assert error.message =~ "future_flag"
  end
end
