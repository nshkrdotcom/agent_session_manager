defmodule ASM.Stream.ShellProviderIntegrationTest do
  use ASM.TestCase

  alias ASM.{Event, Message, Stream}
  alias ASM.Session.Server, as: SessionServer

  test "allow-list command streams stdout as assistant text" do
    session_id = unique_session_id("shell-allow")

    assert {:ok, session} =
             ASM.start_session(
               session_id: session_id,
               provider: :shell,
               allowed_commands: ["echo"],
               denied_commands: []
             )

    try do
      events = ASM.stream(session, "echo SHELL_OK") |> Enum.to_list()

      refute Enum.any?(events, &(&1.kind == :error))
      assert Stream.final_result(events).text =~ "SHELL_OK"
    after
      :ok = ASM.stop_session(session)
    end
  end

  test "command outside allow-list is denied" do
    session_id = unique_session_id("shell-deny")

    assert {:ok, session} =
             ASM.start_session(
               session_id: session_id,
               provider: :shell,
               allowed_commands: ["echo"],
               denied_commands: []
             )

    try do
      assert {:error, error} = ASM.query(session, "uname -a")
      assert error.kind == :policy_violation
      assert error.message =~ "allowed list"
    after
      :ok = ASM.stop_session(session)
    end
  end

  test "command timeout emits timeout error" do
    session_id = unique_session_id("shell-timeout")

    assert {:ok, session} =
             ASM.start_session(
               session_id: session_id,
               provider: :shell,
               allowed_commands: ["sleep"],
               command_timeout_ms: 25
             )

    try do
      assert {:error, error} =
               ASM.query(session, "sleep 1", stream_timeout_ms: 1_000, command_timeout_ms: 25)

      assert error.kind == :timeout
    after
      :ok = ASM.stop_session(session)
    end
  end

  test "cancel interrupts active command run and emits user_cancelled error" do
    session_id = unique_session_id("shell-cancel")

    assert {:ok, session} =
             ASM.start_session(
               session_id: session_id,
               provider: :shell,
               allowed_commands: ["sleep"],
               command_timeout_ms: 5_000
             )

    task =
      Task.async(fn ->
        ASM.stream(session, "sleep 5", stream_timeout_ms: 10_000) |> Enum.to_list()
      end)

    try do
      run_id = wait_for_active_run_id(session)
      assert :ok = ASM.interrupt(session, run_id)

      events = Task.await(task, 2_500)

      assert Enum.any?(events, fn
               %Event{kind: :error, payload: %Message.Error{kind: :user_cancelled}} -> true
               _ -> false
             end)
    after
      _ = Task.shutdown(task, :brutal_kill)
      :ok = ASM.stop_session(session)
    end
  end

  test "non-zero exit status can be treated as success when configured" do
    session_id = unique_session_id("shell-success-codes")

    assert {:ok, session} =
             ASM.start_session(
               session_id: session_id,
               provider: :shell,
               allowed_commands: ["false"],
               success_exit_codes: [0, 1]
             )

    try do
      assert {:ok, result} = ASM.query(session, "false")
      assert result.error == nil
    after
      :ok = ASM.stop_session(session)
    end
  end

  defp wait_for_active_run_id(session, attempts \\ 200)

  defp wait_for_active_run_id(_session, 0), do: flunk("timed out waiting for shell run to start")

  defp wait_for_active_run_id(session, attempts) do
    %{active_runs: active_runs} = SessionServer.get_state(session)

    case Map.keys(active_runs) do
      [run_id | _] ->
        run_id

      [] ->
        Process.sleep(10)
        wait_for_active_run_id(session, attempts - 1)
    end
  end

  defp unique_session_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
