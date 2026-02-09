defmodule AgentSessionManager.PermissionModeTest do
  use ExUnit.Case, async: true

  alias AgentSessionManager.PermissionMode

  @valid_modes [:default, :accept_edits, :plan, :full_auto, :dangerously_skip_permissions]

  describe "all/0" do
    test "returns all valid permission modes" do
      assert PermissionMode.all() == @valid_modes
    end
  end

  describe "valid?/1" do
    test "returns true for each valid mode" do
      for mode <- @valid_modes do
        assert PermissionMode.valid?(mode), "expected #{inspect(mode)} to be valid"
      end
    end

    test "returns false for invalid atoms" do
      refute PermissionMode.valid?(:yolo)
      refute PermissionMode.valid?(:bypass_permissions)
      refute PermissionMode.valid?(:dont_ask)
    end

    test "returns false for non-atom values" do
      refute PermissionMode.valid?("full_auto")
      refute PermissionMode.valid?(nil)
      refute PermissionMode.valid?(42)
    end
  end

  describe "normalize/1" do
    test "passes through valid atoms unchanged" do
      for mode <- @valid_modes do
        assert PermissionMode.normalize(mode) == {:ok, mode}
      end
    end

    test "converts valid string representations to atoms" do
      assert PermissionMode.normalize("default") == {:ok, :default}
      assert PermissionMode.normalize("accept_edits") == {:ok, :accept_edits}
      assert PermissionMode.normalize("plan") == {:ok, :plan}
      assert PermissionMode.normalize("full_auto") == {:ok, :full_auto}

      assert PermissionMode.normalize("dangerously_skip_permissions") ==
               {:ok, :dangerously_skip_permissions}
    end

    test "returns nil for nil input" do
      assert PermissionMode.normalize(nil) == {:ok, nil}
    end

    test "returns error for invalid atoms" do
      assert {:error, _} = PermissionMode.normalize(:yolo)
      assert {:error, _} = PermissionMode.normalize(:bypass_permissions)
    end

    test "returns error for invalid strings" do
      assert {:error, _} = PermissionMode.normalize("yolo")
      assert {:error, _} = PermissionMode.normalize("bypass_permissions")
    end

    test "returns error for non-atom non-string values" do
      assert {:error, _} = PermissionMode.normalize(42)
      assert {:error, _} = PermissionMode.normalize([])
    end
  end
end
