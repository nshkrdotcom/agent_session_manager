defmodule ASM.Runtime.CrashMatrixTest do
  use ASM.SerialTestCase

  alias ASM.Session.Supervisor, as: SessionSupervisor

  test "crashing session server restarts only the aggregate child" do
    %{session_id: session_id, server: server_pid, run_sup: run_sup_pid} = start_session!()
    ref = Process.monitor(server_pid)

    Process.exit(server_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^server_pid, :killed}

    assert {:ok, new_server_pid} = wait_for_restart(session_id, :server, server_pid, 2_000)

    assert is_pid(new_server_pid)
    assert new_server_pid != server_pid

    assert {:ok, ^run_sup_pid} = lookup(session_id, :run_sup)
    assert :ok = SessionSupervisor.stop_session(session_id)
  end

  test "crashing run supervisor restarts run supervisor and session server" do
    %{session_id: session_id, run_sup: run_sup_pid, server: server_pid} = start_session!()

    run_ref = Process.monitor(run_sup_pid)
    server_ref = Process.monitor(server_pid)

    Process.exit(run_sup_pid, :kill)

    assert_receive {:DOWN, ^run_ref, :process, ^run_sup_pid, :killed}
    assert_receive {:DOWN, ^server_ref, :process, ^server_pid, _reason}

    assert {:ok, new_run_sup_pid} = wait_for_restart(session_id, :run_sup, run_sup_pid, 2_000)

    assert {:ok, new_server_pid} = wait_for_restart(session_id, :server, server_pid, 2_000)

    assert new_run_sup_pid != run_sup_pid
    assert new_server_pid != server_pid

    assert :ok = SessionSupervisor.stop_session(session_id)
  end

  test "crashing transport supervisor restarts downstream children" do
    %{
      session_id: session_id,
      transport_sup: transport_sup_pid,
      run_sup: run_sup_pid,
      server: server_pid
    } = start_session!()

    transport_ref = Process.monitor(transport_sup_pid)
    run_ref = Process.monitor(run_sup_pid)
    server_ref = Process.monitor(server_pid)

    Process.exit(transport_sup_pid, :kill)

    assert_receive {:DOWN, ^transport_ref, :process, ^transport_sup_pid, :killed}
    assert_receive {:DOWN, ^run_ref, :process, ^run_sup_pid, _reason}
    assert_receive {:DOWN, ^server_ref, :process, ^server_pid, _reason}

    assert {:ok, new_transport_sup_pid} =
             wait_for_restart(session_id, :transport_sup, transport_sup_pid, 2_000)

    assert {:ok, new_run_sup_pid} = wait_for_restart(session_id, :run_sup, run_sup_pid, 2_000)

    assert {:ok, new_server_pid} = wait_for_restart(session_id, :server, server_pid, 2_000)

    assert new_transport_sup_pid != transport_sup_pid
    assert new_run_sup_pid != run_sup_pid
    assert new_server_pid != server_pid

    assert :ok = SessionSupervisor.stop_session(session_id)
  end

  defp start_session! do
    session_id = "crash-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _subtree_pid} =
             SessionSupervisor.start_session(session_id: session_id, provider: :claude)

    {:ok, server_pid} = lookup(session_id, :server)
    {:ok, run_sup_pid} = lookup(session_id, :run_sup)
    {:ok, transport_sup_pid} = lookup(session_id, :transport_sup)

    %{
      session_id: session_id,
      server: server_pid,
      run_sup: run_sup_pid,
      transport_sup: transport_sup_pid
    }
  end

  defp lookup(session_id, role) do
    case Registry.lookup(:asm_sessions, {session_id, role}) do
      [{pid, _}] -> {:ok, pid}
      [] -> :error
    end
  end

  defp wait_for_restart(session_id, role, old_pid, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_restart(session_id, role, old_pid, deadline)
  end

  defp do_wait_for_restart(session_id, role, old_pid, deadline_ms) do
    case lookup(session_id, role) do
      {:ok, pid} ->
        if pid != old_pid and Process.alive?(pid) do
          {:ok, pid}
        else
          maybe_wait_for_restart(session_id, role, old_pid, deadline_ms)
        end

      _ ->
        maybe_wait_for_restart(session_id, role, old_pid, deadline_ms)
    end
  end

  defp maybe_wait_for_restart(session_id, role, old_pid, deadline_ms) do
    if System.monotonic_time(:millisecond) < deadline_ms do
      Process.sleep(10)
      do_wait_for_restart(session_id, role, old_pid, deadline_ms)
    else
      {:error, :timeout}
    end
  end
end
