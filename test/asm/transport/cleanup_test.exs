defmodule ASM.Transport.CleanupTest do
  use ASM.TestCase

  alias ASM.Transport.Cleanup

  test "close/2 escalates to kill for stubborn processes" do
    pid =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        stubborn_loop()
      end)

    assert_process_alive(pid)

    assert :ok =
             Cleanup.close(
               pid,
               close_fun: fn _ -> :ok end,
               close_grace_ms: 10,
               shutdown_grace_ms: 10,
               kill_grace_ms: 10
             )

    assert match?({:ok, _reason}, wait_for_process_death(pid, 1_000))
  end

  test "close/2 is safe for already-dead processes" do
    pid = spawn(fn -> :ok end)
    assert match?({:ok, _reason}, wait_for_process_death(pid, 1_000))

    assert :ok =
             Cleanup.close(
               pid,
               close_fun: fn _ -> :ok end,
               close_grace_ms: 10,
               shutdown_grace_ms: 10,
               kill_grace_ms: 10
             )
  end

  defp stubborn_loop do
    receive do
      {:EXIT, _from, _reason} ->
        stubborn_loop()

      :stop ->
        :ok
    end
  end
end
