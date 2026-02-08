defmodule AgentSessionManager.Runtime.SessionSupervisorTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Runtime.SessionSupervisor
  alias AgentSessionManager.SessionManager

  setup ctx do
    {:ok, store} = InMemorySessionStore.start_link([])
    {:ok, adapter} = MockProviderAdapter.start_link([])

    cleanup_on_exit(fn -> safe_stop(store) end)
    cleanup_on_exit(fn -> safe_stop(adapter) end)

    ctx
    |> Map.put(:store, store)
    |> Map.put(:adapter, adapter)
  end

  test "starts SessionServer processes and registers them by session_id", %{
    store: store,
    adapter: adapter
  } do
    {:ok, session} = SessionManager.start_session(store, adapter, %{agent_id: "agent"})

    sup_name = :"runtime_sup_#{System.unique_integer([:positive])}"
    {:ok, sup} = SessionSupervisor.start_link(name: sup_name)
    cleanup_on_exit(fn -> safe_stop(sup) end)

    assert {:ok, pid} =
             SessionSupervisor.start_session(sup_name,
               session_id: session.id,
               store: store,
               adapter: adapter
             )

    assert Process.alive?(pid)
    assert {:ok, ^pid} = SessionSupervisor.whereis(sup_name, session.id)
  end
end
