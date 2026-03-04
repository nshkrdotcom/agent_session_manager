defmodule ASM.Remote.CapabilitiesTest do
  use ExUnit.Case, async: true

  alias ASM.Remote.Capabilities

  test "handshake/0 advertises runtime version and capabilities" do
    handshake = Capabilities.handshake()

    assert is_binary(handshake.asm_version)
    assert is_binary(handshake.otp_release)
    assert is_list(handshake.capabilities)
    assert :remote_transport_start_v1 in handshake.capabilities
  end

  test "version compatibility accepts patch/build differences" do
    assert Capabilities.version_compatible?("0.9.0-dev", "0.9.7+build.1")
    refute Capabilities.version_compatible?("0.9.0", "0.10.0")
    refute Capabilities.version_compatible?("0.9.0", "1.9.0")
  end
end
