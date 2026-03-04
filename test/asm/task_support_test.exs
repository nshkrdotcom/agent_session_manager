defmodule ASM.TaskSupportTest do
  use ASM.SerialTestCase

  alias ASM.TaskSupport

  setup do
    on_exit(fn ->
      Application.ensure_all_started(:agent_session_manager)
    end)

    :ok
  end

  test "async_nolink/1 ensures app task supervisor is started when app was stopped" do
    :ok = Application.stop(:agent_session_manager)
    assert Process.whereis(ASM.TaskSupervisor) == nil

    assert {:ok, task} = TaskSupport.async_nolink(fn -> :ok end)
    assert {:ok, :ok} = Task.yield(task, 500) || Task.shutdown(task, :brutal_kill)
    assert is_pid(Process.whereis(ASM.TaskSupervisor))
  end

  test "async_nolink/2 returns :noproc for a missing custom supervisor" do
    assert {:error, :noproc} =
             TaskSupport.async_nolink(:asm_missing_supervisor, fn -> :ok end)
  end
end
