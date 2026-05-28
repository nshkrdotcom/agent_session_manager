defmodule ASM.PermissionTest do
  use ASM.TestCase

  alias ASM.{Permission, ProviderFeatures}

  test "Cursor bypass maps to the core force argv without making ask a permission" do
    assert {:ok, %{normalized: :bypass, native: :bypass}} =
             Permission.normalize(:cursor, :bypass)

    assert {:ok, %{normalized: :bypass, native: :bypass}} =
             Permission.normalize(:cursor, "force")

    assert ProviderFeatures.permission_mode!(:cursor, :bypass).cli_args == ["--force"]
    assert ProviderFeatures.permission_mode!(:cursor, :bypass).cli_excerpt == "--force"

    assert {:error, error} = Permission.normalize(:cursor, :ask)
    assert String.contains?(error.message, "Permission mode :ask is not valid")
  end
end
