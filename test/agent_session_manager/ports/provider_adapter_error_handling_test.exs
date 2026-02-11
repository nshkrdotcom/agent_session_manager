defmodule AgentSessionManager.Ports.ProviderAdapterErrorHandlingTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Ports.ProviderAdapter

  describe "execute/4 error normalization" do
    test "returns provider_unavailable instead of exiting when adapter is down" do
      {:ok, adapter} = MockProviderAdapter.start_link(execution_mode: :instant)
      :ok = safe_stop(adapter)

      {:ok, session} = Session.new(%{agent_id: "test-agent"})
      {:ok, run} = Run.new(%{session_id: session.id, input: %{prompt: "hello"}})

      assert {:error, %Error{code: :provider_unavailable}} =
               ProviderAdapter.execute(adapter, run, session, [])
    end

    test "returns provider_timeout instead of exiting when execute call times out" do
      {:ok, adapter} = MockProviderAdapter.start_link(execution_mode: :timeout)
      cleanup_on_exit(fn -> safe_stop(adapter) end)

      {:ok, session} = Session.new(%{agent_id: "test-agent"})
      {:ok, run} = Run.new(%{session_id: session.id, input: %{prompt: "hello"}})

      assert {:error, %Error{code: :provider_timeout}} =
               ProviderAdapter.execute(adapter, run, session, timeout: 1)
    end
  end

  describe "resolve_execute_timeout/1" do
    test "supports unbounded timeout sentinels with one-week emergency cap" do
      assert ProviderAdapter.resolve_execute_timeout_base(timeout: :unbounded) == 604_800_000
      assert ProviderAdapter.resolve_execute_timeout_base(timeout: :infinity) == 604_800_000
      assert ProviderAdapter.resolve_execute_timeout_base(timeout: "infinity") == 604_800_000
      assert ProviderAdapter.resolve_execute_timeout_base(timeout: "unbounded") == 604_800_000
    end

    test "clamps oversized explicit timeout to the one-week emergency cap" do
      assert ProviderAdapter.resolve_execute_timeout_base(timeout: 604_800_001) == 604_800_000
      assert ProviderAdapter.resolve_execute_timeout_base(timeout: "604800999") == 604_800_000
    end

    test "adds execute grace timeout to normalized execute timeout" do
      assert ProviderAdapter.resolve_execute_timeout(timeout: 1_000) == 6_000
      assert ProviderAdapter.resolve_execute_timeout(timeout: :unbounded) == 604_805_000
    end
  end
end
