defmodule ASM.PermissionTest do
  use ASM.TestCase

  alias ASM.Permission

  test "normalizes provider-native claude mode to common mode" do
    assert {:ok, %{normalized: :auto, native: :accept_edits}} =
             Permission.normalize(:claude, :accept_edits)
  end

  test "normalizes common bypass mode to provider-native mode" do
    assert {:ok, %{normalized: :bypass, native: :yolo}} =
             Permission.normalize(:codex_exec, :bypass)
  end

  test "supports safe string mode inputs without atom creation" do
    assert {:ok, %{normalized: :bypass, native: :yolo}} =
             Permission.normalize(:gemini, "yolo")
  end

  test "normalizes amp bypass mode to dangerously allow all" do
    assert {:ok, %{normalized: :bypass, native: :dangerously_allow_all}} =
             Permission.normalize(:amp, :bypass)
  end

  test "returns typed config error for unsupported provider mode" do
    assert {:error, error} = Permission.normalize(:gemini, :accept_edits)

    assert error.kind == :config_invalid
    assert error.domain == :config
  end
end
