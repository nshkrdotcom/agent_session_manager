defmodule ASM.OptionsTest do
  use ASM.TestCase

  alias ASM.Options

  test "validate/2 merges provider schema and applies defaults" do
    schema = [sandbox: [type: :boolean, default: false]]

    assert {:ok, opts} = Options.validate([provider: :gemini], schema)

    assert opts[:sandbox] == false
    assert opts[:permission_mode] == :default
    assert opts[:provider_permission_mode] == :default
  end

  test "validate/2 normalizes permission mode and stores provider-native mode" do
    assert {:ok, opts} = Options.validate(provider: :codex_exec, permission_mode: :bypass)

    assert opts[:permission_mode] == :bypass
    assert opts[:provider_permission_mode] == :yolo
  end

  test "validate/2 supports amp provider schema and permission normalization" do
    assert {:ok, opts} =
             Options.validate(
               [provider: :amp, permission_mode: :bypass, mode: "smart", include_thinking: true],
               ASM.Options.Amp.schema()
             )

    assert opts[:mode] == "smart"
    assert opts[:include_thinking] == true
    assert opts[:provider_permission_mode] == :dangerously_allow_all
  end

  test "validate/2 rejects reserved key collisions in provider schema" do
    schema = [provider: [type: :atom, required: true]]

    assert {:error, error} = Options.validate([provider: :claude], schema)
    assert error.kind == :config_invalid
  end

  test "validate/2 returns typed error for invalid overflow policy" do
    assert {:error, error} = Options.validate(provider: :claude, overflow_policy: :invalid)

    assert error.kind == :config_invalid
    assert error.domain == :config
  end
end
