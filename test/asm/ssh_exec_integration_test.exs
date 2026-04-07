defmodule ASM.SSHExecIntegrationTest do
  use ASM.SerialTestCase

  alias ASM.Event
  alias ASM.Message.Error, as: ErrorMessage
  alias ASM.ProviderBackend.Core
  alias CliSubprocessCore.TestSupport.FakeSSH

  test "query/3 runs over SSHExec through the unchanged ASM execution config" do
    fake_ssh = FakeSSH.new!()
    cli_path = write_script!(codex_success_script("SSH_QUERY_OK"))

    on_exit(fn ->
      FakeSSH.cleanup(fake_ssh)
    end)

    session =
      start_session!(
        provider: :codex,
        execution_surface: [
          surface_kind: :ssh_exec,
          transport_options:
            FakeSSH.transport_options(fake_ssh,
              destination: "asm.ssh.query.example",
              port: 2222
            )
        ]
      )

    assert {:ok, info} = ASM.session_info(session)
    assert info.options[:execution_surface].surface_kind == :ssh_exec

    assert info.options[:execution_surface].transport_options[:destination] ==
             "asm.ssh.query.example"

    assert info.options[:execution_surface].transport_options[:port] == 2222

    assert {:ok, result} = ASM.query(session, "say hello", cli_path: cli_path)
    assert result.text == "SSH_QUERY_OK"
    assert result.metadata.backend == Core
    assert result.metadata.execution_mode == :local
    assert result.metadata.lane == :core

    assert FakeSSH.wait_until_written(fake_ssh, 1_000) == :ok
    assert FakeSSH.read_manifest!(fake_ssh) =~ "destination=asm.ssh.query.example"

    assert :ok = ASM.stop_session(session)
  end

  test "stream/3 plus interrupt/2 cancels the active SSHExec run through ASM" do
    fake_ssh = FakeSSH.new!()
    cli_path = write_script!(interrupt_script())

    on_exit(fn ->
      FakeSSH.cleanup(fake_ssh)
    end)

    session =
      start_session!(
        provider: :codex,
        execution_surface: [
          surface_kind: :ssh_exec,
          transport_options:
            FakeSSH.transport_options(fake_ssh,
              destination: "asm.ssh.interrupt.example"
            )
        ]
      )

    parent = self()

    task =
      Task.async(fn ->
        session
        |> ASM.stream("interrupt me", cli_path: cli_path)
        |> Enum.each(fn event -> send(parent, {:asm_event, event}) end)
      end)

    assert_receive {:asm_event, %Event{kind: :run_started, run_id: run_id}}, 2_000
    assert FakeSSH.wait_until_written(fake_ssh, 1_000) == :ok
    assert :ok = ASM.interrupt(session, run_id)

    assert_receive {:asm_event, %Event{kind: :error} = event}, 2_000

    assert %ErrorMessage{kind: :user_cancelled, message: "Run interrupted"} =
             Event.legacy_payload(event)

    assert :ok = Task.await(task, 2_000)
    assert FakeSSH.wait_until_written(fake_ssh, 1_000) == :ok
    assert FakeSSH.read_manifest!(fake_ssh) =~ "destination=asm.ssh.interrupt.example"

    assert :ok = ASM.stop_session(session)
  end

  defp start_session!(opts) when is_list(opts) do
    session_id = "asm-ssh-#{System.unique_integer([:positive])}"
    {:ok, session} = ASM.start_session(Keyword.put(opts, :session_id, session_id))
    session
  end

  defp codex_success_script(text) do
    """
    #!/usr/bin/env bash
    set -euo pipefail
    echo '{"type":"thread.started","thread_id":"thread-1"}'
    echo '{"type":"turn.started"}'
    echo '{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"#{text}"}}'
    echo '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
    """
  end

  defp interrupt_script do
    """
    #!/usr/bin/env bash
    set -euo pipefail
    trap 'exit 130' INT
    while true; do
      sleep 0.1
    done
    """
  end

  defp write_script!(contents) do
    path = Path.join(temp_dir!("script"), "fixture.sh")
    File.write!(path, contents)
    File.chmod!(path, 0o755)
    path
  end

  defp temp_dir!(prefix) do
    dir =
      Path.join(System.tmp_dir!(), "asm_ssh_exec_#{prefix}_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    dir
  end
end
