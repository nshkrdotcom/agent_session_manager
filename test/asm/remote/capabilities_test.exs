defmodule ASM.Remote.CapabilitiesTest do
  use ASM.TestCase, async: true

  alias ASM.Remote.Capabilities

  test "version_compatible/2 reads major and minor number groups with fixed parsing" do
    assert Capabilities.version_compatible?("0.9.2", "0-9-build7")
    refute Capabilities.version_compatible?("0.9.2", "0.10.0")
    refute Capabilities.version_compatible?("bad", "0.9.2")
  end
end
