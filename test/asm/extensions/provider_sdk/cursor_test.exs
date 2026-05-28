defmodule ASM.Extensions.ProviderSDK.CursorTest do
  use ASM.SerialTestCase

  alias ASM.Extensions.ProviderSDK.Cursor
  alias ASM.Options.{ProviderMismatchError, ProviderNativeOptionError}
  alias ASM.TestSupport.OptionalSDK

  setup do
    original = Application.get_env(:agent_session_manager, ASM.ProviderRegistry)

    Application.put_env(
      :agent_session_manager,
      ASM.ProviderRegistry,
      runtime_loader: OptionalSDK.loaded_runtime_loader([:cursor])
    )

    on_exit(fn ->
      if is_nil(original) do
        Application.delete_env(:agent_session_manager, ASM.ProviderRegistry)
      else
        Application.put_env(:agent_session_manager, ASM.ProviderRegistry, original)
      end
    end)

    :ok
  end

  test "extension metadata is registered with the SDK dependency wired" do
    extension = Cursor.extension()

    assert extension.id == :cursor
    assert extension.provider == :cursor
    assert extension.namespace == Cursor
    assert extension.sdk_app == :cursor_cli_sdk
    assert extension.sdk_module == CursorCliSdk
    assert extension.sdk_available?
    assert :mcp in extension.native_capabilities
    assert CursorCliSdk.Runtime.CLI in extension.native_surface_modules
  end

  test "derive_options/2 rejects Cursor native settings in generic ASM input" do
    assert {:error, %ProviderNativeOptionError{} = error} =
             Cursor.derive_options(cwd: "/tmp/asm-cursor-extension", approve_mcps: true)

    assert error.key == :approve_mcps
    assert error.provider == :cursor
  end

  test "derive_options/2 rejects redundant provider options in strict common input" do
    assert {:error, %ProviderMismatchError{} = error} =
             Cursor.derive_options(provider: :cursor, cwd: "/tmp/asm-cursor-extension")

    assert error.reason == :redundant_provider
  end

  test "derive_options/2 rejects native overrides that redefine ASM-derived fields" do
    assert {:error, error} =
             Cursor.derive_options([cwd: "/tmp/asm-cursor-extension"],
               native_overrides: [cwd: "/tmp/native"]
             )

    assert error.kind == :config_invalid
    assert error.domain == :config
    assert String.contains?(error.message, "native_overrides")
    assert String.contains?(error.message, ":cwd")
  end

  test "derive_options/2 builds CursorCliSdk.Options after strict common validation succeeds" do
    assert {:ok, %CursorCliSdk.Options{} = options} =
             Cursor.derive_options([cwd: "/tmp/asm-cursor-extension"],
               native_overrides: [mode: :ask, approve_mcps: true]
             )

    assert options.cwd == "/tmp/asm-cursor-extension"
    assert options.mode == :ask
    assert options.approve_mcps == true
  end
end
