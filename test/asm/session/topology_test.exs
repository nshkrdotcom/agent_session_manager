defmodule ASM.Session.TopologyTest do
  use ExUnit.Case, async: true

  alias ASM.Session.Server
  alias ASM.Session.Supervisor, as: SessionSupervisor

  test "start_session/1 boots subtree and registers session processes" do
    session_id = "session-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, subtree_pid} =
             SessionSupervisor.start_session(session_id: session_id, provider: :claude)

    assert Process.alive?(subtree_pid)

    assert {:ok, server_pid} = lookup(session_id, :server)
    assert {:ok, transport_sup_pid} = lookup(session_id, :transport_sup)
    assert {:ok, run_sup_pid} = lookup(session_id, :run_sup)
    assert {:ok, subtree_registry_pid} = lookup(session_id, :subtree)

    assert subtree_pid == subtree_registry_pid
    refute server_pid == transport_sup_pid
    refute server_pid == run_sup_pid
    refute server_pid == subtree_registry_pid

    assert %{session_id: ^session_id} = Server.get_state(server_pid)
  end

  test "stop_session/1 terminates subtree and unregisters keys" do
    session_id = "session-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _pid} =
             SessionSupervisor.start_session(session_id: session_id, provider: :claude)

    assert :ok = SessionSupervisor.stop_session(session_id)

    assert_lookup_absent(session_id, :server)
    assert_lookup_absent(session_id, :transport_sup)
    assert_lookup_absent(session_id, :run_sup)
    assert_lookup_absent(session_id, :subtree)
  end

  defp lookup(session_id, role) do
    case Registry.lookup(:asm_sessions, {session_id, role}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp assert_lookup_absent(session_id, role, attempts \\ 20)

  defp assert_lookup_absent(session_id, role, attempts) when attempts > 0 do
    case lookup(session_id, role) do
      :error ->
        assert true

      {:ok, _pid} ->
        Process.sleep(10)
        assert_lookup_absent(session_id, role, attempts - 1)
    end
  end

  defp assert_lookup_absent(session_id, role, 0) do
    assert :error = lookup(session_id, role)
  end
end
