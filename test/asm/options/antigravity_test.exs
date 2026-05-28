defmodule ASM.Options.AntigravityTest do
  use ASM.TestCase

  alias ASM.{Options, Provider}
  alias ASM.Options.ProviderNativeOptionError

  @schema Provider.resolve!(:antigravity).options_schema

  test "validates Antigravity native options behind the provider schema" do
    assert {:ok, validated} =
             Options.validate(
               [
                 provider: :antigravity,
                 permission_mode: :bypass,
                 sandbox: true,
                 dangerously_skip_permissions: true,
                 conversation: "conversation-1",
                 continue: true,
                 add_dirs: ["/repo"],
                 print_timeout: "45s",
                 log_file: "/tmp/agy.log"
               ],
               @schema
             )

    assert validated[:provider] == :antigravity
    assert validated[:permission_mode] == :bypass
    assert validated[:provider_permission_mode] == :bypass
    assert validated[:sandbox] == true
    assert validated[:dangerously_skip_permissions] == true
    assert validated[:conversation] == "conversation-1"
    assert validated[:continue] == true
    assert validated[:add_dirs] == ["/repo"]
  end

  test "strict preflight rejects Antigravity native options outside native boundaries" do
    assert {:error, %ProviderNativeOptionError{} = error} =
             Options.preflight(:antigravity, dangerously_skip_permissions: true)

    assert error.key == :dangerously_skip_permissions
    assert error.provider == :antigravity

    assert {:error, %ProviderNativeOptionError{} = error} =
             Options.preflight(:antigravity, add_dirs: ["/repo"])

    assert error.key == :add_dirs
    assert error.provider == :antigravity
  end

  test "finalize_provider_opts attaches the Antigravity default model payload" do
    assert {:ok, validated} = Options.validate([provider: :antigravity], @schema)
    assert {:ok, finalized} = Options.finalize_provider_opts(:antigravity, validated)

    payload = Keyword.fetch!(finalized, :model_payload)

    assert payload.provider == :antigravity
    assert payload.requested_model == nil
    assert payload.resolved_model == "default"
    refute Keyword.has_key?(finalized, :model)
  end
end
