defmodule AgentSessionManager.Policy.AdapterCompilerTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Policy.{AdapterCompiler, Policy}

  describe "compile/2" do
    test "compiles deny rules into denied_tools" do
      {:ok, policy} = Policy.new(name: "test", tool_rules: [{:deny, ["bash", "exec"]}])

      opts = AdapterCompiler.compile(policy, "claude")
      assert opts[:denied_tools] == ["bash", "exec"]
    end

    test "compiles allow rules into allowed_tools" do
      {:ok, policy} = Policy.new(name: "test", tool_rules: [{:allow, ["search", "read"]}])

      opts = AdapterCompiler.compile(policy, "claude")
      assert Enum.sort(opts[:allowed_tools]) == ["read", "search"]
    end

    test "intersects multiple allow lists and subtracts deny lists" do
      {:ok, policy} =
        Policy.new(
          name: "test",
          tool_rules: [
            {:allow, ["search", "read", "write"]},
            {:allow, ["search", "read"]},
            {:deny, ["read"]}
          ]
        )

      opts = AdapterCompiler.compile(policy, "claude")
      assert opts[:allowed_tools] == ["search"]
    end

    test "compiles max_total_tokens into max_tokens" do
      {:ok, policy} = Policy.new(name: "test", limits: [{:max_total_tokens, 4_000}])

      opts = AdapterCompiler.compile(policy, "claude")
      assert opts[:max_tokens] == 4_000
    end

    test "returns empty opts when policy has no enforceable constraints" do
      {:ok, policy} = Policy.new(name: "test", limits: [{:max_duration_ms, 60_000}])

      opts = AdapterCompiler.compile(policy, "claude")
      assert opts == []
    end

    test "handles nil policy gracefully" do
      assert AdapterCompiler.compile(nil, "claude") == []
    end
  end
end
