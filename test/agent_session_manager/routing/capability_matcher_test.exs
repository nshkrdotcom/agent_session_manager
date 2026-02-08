defmodule AgentSessionManager.Routing.CapabilityMatcherTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Core.Capability
  alias AgentSessionManager.Routing.CapabilityMatcher

  describe "matches_all?/2" do
    test "matches type-and-name capability requirements" do
      capabilities = [
        %Capability{name: "bash", type: :tool, enabled: true},
        %Capability{name: "chat", type: :tool, enabled: true}
      ]

      requirements = [%{type: :tool, name: "bash"}]

      assert CapabilityMatcher.matches_all?(capabilities, requirements)
    end

    test "matches type-only requirements when name is nil" do
      capabilities = [
        %Capability{name: "chat", type: :tool, enabled: true}
      ]

      requirements = [%{type: :tool, name: nil}]

      assert CapabilityMatcher.matches_all?(capabilities, requirements)
    end

    test "does not match when capability names differ" do
      capabilities = [
        %Capability{name: "chat", type: :tool, enabled: true}
      ]

      requirements = [%{type: :tool, name: "bash"}]

      refute CapabilityMatcher.matches_all?(capabilities, requirements)
    end

    test "ignores disabled capabilities" do
      capabilities = [
        %Capability{name: "bash", type: :tool, enabled: false}
      ]

      requirements = [%{type: :tool, name: "bash"}]

      refute CapabilityMatcher.matches_all?(capabilities, requirements)
    end
  end
end
