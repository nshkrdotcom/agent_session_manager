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
end
