defmodule ASM.Runtime.CrashMatrixTest do
  use ExUnit.Case, async: false

  alias ASM.Session.Supervisor, as: SessionSupervisor

  test "crashing session server restarts only the aggregate child" do
    %{session_id: session_id, server: server_pid, run_sup: run_sup_pid} = start_session!()
    ref = Process.monitor(server_pid)

    Process.exit(server_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^server_pid, :killed}

    assert_eventually(fn ->
      case lookup(session_id, :server) do
        {:ok, new_server_pid} -> Process.alive?(new_server_pid) and new_server_pid != server_pid
        :error -> false
      end
    end)

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

    assert_eventually(fn ->
      with {:ok, new_run_sup_pid} <- lookup(session_id, :run_sup),
           {:ok, new_server_pid} <- lookup(session_id, :server) do
        Process.alive?(new_run_sup_pid) and Process.alive?(new_server_pid) and
          new_run_sup_pid != run_sup_pid and new_server_pid != server_pid
      else
        :error -> false
      end
    end)

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

    assert_eventually(fn ->
      with {:ok, new_transport_sup_pid} <- lookup(session_id, :transport_sup),
           {:ok, new_run_sup_pid} <- lookup(session_id, :run_sup),
           {:ok, new_server_pid} <- lookup(session_id, :server) do
        Process.alive?(new_transport_sup_pid) and Process.alive?(new_run_sup_pid) and
          Process.alive?(new_server_pid) and
          new_transport_sup_pid != transport_sup_pid and
          new_run_sup_pid != run_sup_pid and
          new_server_pid != server_pid
      else
        :error -> false
      end
    end)

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

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0) do
    assert fun.()
  end
end
