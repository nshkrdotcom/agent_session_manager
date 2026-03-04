defmodule ASM.Remote.TransportStarterTest do
  use ExUnit.Case, async: false

  alias ASM.Remote.TransportStarter

  setup do
    ensure_remote_transport_supervisor_started()
    :ok
  end

  test "start_transport/1 starts temporary child under remote transport supervisor" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail
      while true; do sleep 0.1; done
      """)

    cwd = Path.join(System.tmp_dir!(), "asm-remote-starter-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(cwd) end)

    ctx = %{
      provider: :codex,
      prompt: "hello",
      provider_opts: [cli_path: script],
      remote_cwd: cwd,
      remote_boot_lease_timeout_ms: 500
    }

    assert {:ok, transport_pid} = TransportStarter.start_transport(ctx)
    assert Process.alive?(transport_pid)

    ref = Process.monitor(transport_pid)
    Process.exit(transport_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^transport_pid, :killed}

    assert_eventually(fn ->
      child_pids()
      |> Enum.reject(&is_nil/1)
      |> Enum.all?(fn pid -> pid != transport_pid end)
    end)
  end

  test "start_transport/1 returns workspace failure when remote cwd cannot be created" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail
      sleep 1
      """)

    parent =
      Path.join(
        System.tmp_dir!(),
        "asm-remote-starter-file-#{System.unique_integer([:positive])}"
      )

    File.write!(parent, "not-a-directory")
    on_exit(fn -> File.rm_rf!(parent) end)

    ctx = %{
      provider: :codex,
      prompt: "hello",
      provider_opts: [cli_path: script],
      remote_cwd: Path.join(parent, "child"),
      remote_boot_lease_timeout_ms: 500
    }

    assert {:error, {:workspace_failed, _reason}} = TransportStarter.start_transport(ctx)
  end

  test "start_transport/1 surfaces cli resolution failures" do
    cwd =
      Path.join(System.tmp_dir!(), "asm-remote-cli-missing-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(cwd) end)

    ctx = %{
      provider: :codex,
      prompt: "hello",
      provider_opts: [cli_path: "/definitely/missing/codex-binary"],
      remote_cwd: cwd,
      remote_boot_lease_timeout_ms: 500
    }

    assert {:error, :cli_not_found} = TransportStarter.start_transport(ctx)
  end

  defp ensure_remote_transport_supervisor_started do
    case Process.whereis(ASM.Remote.TransportSupervisor) do
      nil ->
        {:ok, _pid} = start_supervised({ASM.Remote.TransportSupervisor, []})
        :ok

      _pid ->
        :ok
    end
  end

  defp child_pids do
    DynamicSupervisor.which_children(ASM.Remote.TransportSupervisor)
    |> Enum.map(fn {_id, pid, _type, _modules} -> pid end)
  end

  defp assert_eventually(fun, attempts \\ 30)

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

  defp write_script!(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "asm-remote-transport-starter-#{System.unique_integer([:positive])}.sh"
      )

    File.write!(path, contents)
    File.chmod!(path, 0o755)
    path
  end
end
