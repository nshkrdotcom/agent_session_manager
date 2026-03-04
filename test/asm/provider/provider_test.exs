defmodule ASM.ProviderTest do
  use ASM.TestCase

  alias ASM.Provider

  test "resolve/1 accepts provider alias codex -> codex_exec profile" do
    assert {:ok, provider} = Provider.resolve(:codex)
    assert provider.name == :codex_exec
    assert provider.profile.transport_mode == :exec_stdio
  end

  test "resolve/1 accepts provider struct passthrough" do
    provider = %Provider{
      name: :custom,
      display_name: "Custom",
      binary_names: ["custom-cli"],
      env_var: "CUSTOM_CLI_PATH",
      parser: ASM.Parser,
      command_builder: ASM.Command,
      profile: %ASM.Provider.Profile{
        transport_mode: :exec_stdio,
        input_mode: :stdin,
        control_mode: :none,
        session_mode: :asm_managed
      }
    }

    assert {:ok, ^provider} = Provider.resolve(provider)
  end

  test "resolve/1 returns typed config error for unknown provider" do
    assert {:error, error} = Provider.resolve(:unknown_provider)
    assert error.kind == :config_invalid
    assert error.domain == :config
  end
end
