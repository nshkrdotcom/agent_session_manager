defmodule ASM.SSHExecIntegrationTest do
  use ASM.SerialTestCase

  alias ASM.Event
  alias ASM.Message.Error, as: ErrorMessage
  alias ASM.ProviderBackend.Core

  test "query/3 runs over SSHExec through the unchanged ASM execution config" do
    manifest_path = temp_path!("query_manifest.txt")
    ssh_path = create_fake_ssh!(manifest_path)
    cli_path = write_script!(codex_success_script("SSH_QUERY_OK"))

    session =
      start_session!(
        provider: :codex,
        surface_kind: :static_ssh,
        transport_options: [
          ssh_path: ssh_path,
          destination: "asm.ssh.query.example",
          port: 2222
        ]
      )

    assert {:ok, info} = ASM.session_info(session)
    assert info.options[:surface_kind] == :static_ssh
    assert info.options[:transport_options][:destination] == "asm.ssh.query.example"
    assert info.options[:transport_options][:port] == 2222

    assert {:ok, result} = ASM.query(session, "say hello", cli_path: cli_path)
    assert result.text == "SSH_QUERY_OK"
    assert result.metadata.backend == Core
    assert result.metadata.execution_mode == :local
    assert result.metadata.lane == :core

    assert_eventually(fn -> File.exists?(manifest_path) end)
    assert File.read!(manifest_path) =~ "destination=asm.ssh.query.example"

    assert :ok = ASM.stop_session(session)
  end

  test "stream/3 plus interrupt/2 cancels the active SSHExec run through ASM" do
    manifest_path = temp_path!("interrupt_manifest.txt")
    ssh_path = create_fake_ssh!(manifest_path)
    cli_path = write_script!(interrupt_script())

    session =
      start_session!(
        provider: :codex,
        surface_kind: :static_ssh,
        transport_options: [
          ssh_path: ssh_path,
          destination: "asm.ssh.interrupt.example"
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
    assert_eventually(fn -> File.exists?(manifest_path) end)
    assert :ok = ASM.interrupt(session, run_id)

    assert_receive {:asm_event, %Event{kind: :error} = event}, 2_000

    assert %ErrorMessage{kind: :user_cancelled, message: "Run interrupted"} =
             Event.legacy_payload(event)

    assert :ok = Task.await(task, 2_000)
    assert_eventually(fn -> File.exists?(manifest_path) end)
    assert File.read!(manifest_path) =~ "destination=asm.ssh.interrupt.example"

    assert :ok = ASM.stop_session(session)
  end

  defp start_session!(opts) when is_list(opts) do
    session_id = "asm-ssh-#{System.unique_integer([:positive])}"
    {:ok, session} = ASM.start_session(Keyword.put(opts, :session_id, session_id))
    session
  end

  defp create_fake_ssh!(manifest_path) do
    dir = temp_dir!("fake_ssh")
    path = Path.join(dir, "ssh")

    File.write!(path, """
    #!/usr/bin/env bash
    set -euo pipefail

    destination=""
    port=""

    while [ "$#" -gt 0 ]; do
      case "$1" in
        -p)
          port="$2"
          shift 2
          ;;
        -o)
          shift 2
          ;;
        --)
          shift
          break
          ;;
        -*)
          shift
          ;;
        *)
          destination="$1"
          shift
          break
          ;;
      esac
    done

    remote_command="${1:-}"

    cat > "#{manifest_path}" <<EOF
    destination=${destination}
    port=${port}
    remote_command=${remote_command}
    EOF

    exec /bin/sh -lc "$remote_command"
    """)

    File.chmod!(path, 0o755)
    path
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

  defp temp_path!(name) do
    Path.join(temp_dir!("tmp"), name)
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

  defp assert_eventually(fun, attempts \\ 40)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(25)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0) do
    flunk("condition did not become true")
  end
end
