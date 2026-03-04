defmodule ASM.Transport.PortTest do
  use ASM.TestCase

  import Supertester.GenServerHelpers, only: [call_with_timeout: 3]

  alias ASM.Error
  alias ASM.Transport
  alias ASM.Transport.Port

  test "attach/detach enforce lease ownership" do
    assert {:ok, port} = Port.start_link([])

    assert {:ok, :attached} = Transport.attach(port, self())
    assert {:error, :busy} = Transport.attach(port, spawn(fn -> :ok end))
    assert {:error, :not_leasee} = Transport.detach(port, spawn(fn -> :ok end))
    assert :ok = Transport.detach(port, self())
  end

  test "only leasee demand drains queue" do
    assert {:ok, port} = Port.start_link([])
    other_pid = spawn(fn -> Process.sleep(:infinity) end)

    assert {:ok, :attached} = Transport.attach(port, self())
    assert :ok = Port.inject(port, %{"type" => "message"})
    assert :ok = Transport.demand(port, other_pid, 1)
    refute_receive {:transport_message, _}, 20

    assert :ok = Transport.demand(port, self(), 1)
    assert_receive {:transport_message, %{"type" => "message"}}

    Process.exit(other_pid, :kill)
    assert :ok = Transport.detach(port, self())
  end

  test "lease is released when leasee process exits" do
    assert {:ok, port} = Port.start_link([])

    leasee =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, :attached} = Transport.attach(port, leasee)
    send(leasee, :stop)

    assert_eventually(fn ->
      match?({:ok, :attached}, Transport.attach(port, self()))
    end)
  end

  test "overflow policy fail_run emits transport error and terminates transport" do
    old_flag = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, old_flag) end)

    assert {:ok, port} = Port.start_link(queue_limit: 1, overflow_policy: :fail_run)
    ref = Process.monitor(port)

    assert {:ok, :attached} = Transport.attach(port, self())
    assert :ok = Port.inject(port, %{"n" => 1})
    assert :ok = Port.inject(port, %{"n" => 2})

    assert_receive {:transport_error, :buffer_overflow}
    assert_receive {:EXIT, ^port, {:shutdown, :buffer_overflow}}
    assert_receive {:DOWN, ^ref, :process, ^port, {:shutdown, :buffer_overflow}}
  end

  test "overflow policy drop_oldest keeps newest queued item" do
    assert {:ok, port} = Port.start_link(queue_limit: 1, overflow_policy: :drop_oldest)

    assert {:ok, :attached} = Transport.attach(port, self())
    assert :ok = Port.inject(port, %{"n" => 1})
    assert :ok = Port.inject(port, %{"n" => 2})

    assert :ok = Transport.demand(port, self(), 1)
    assert_receive {:transport_message, %{"n" => 2}}
    refute_receive {:transport_message, %{"n" => 1}}, 20
  end

  test "overflow policy block drops incoming message while preserving queue" do
    assert {:ok, port} = Port.start_link(queue_limit: 1, overflow_policy: :block)

    assert {:ok, :attached} = Transport.attach(port, self())
    assert :ok = Port.inject(port, %{"n" => 1})
    assert :ok = Port.inject(port, %{"n" => 2})

    assert :ok = Transport.demand(port, self(), 1)
    assert_receive {:transport_message, %{"n" => 1}}
    refute_receive {:transport_message, %{"n" => 2}}, 20
  end

  test "send_input/3 writes to subprocess stdin and emits decoded messages" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail

      if read -r line; then
        echo "{\\"type\\":\\"assistant_delta\\",\\"delta\\":\\"${line}\\"}"
        echo "{\\"type\\":\\"result\\",\\"stop_reason\\":\\"end_turn\\"}"
      fi
      """)

    assert {:ok, port} =
             Port.start_link(
               program: script,
               args: [],
               queue_limit: 8,
               overflow_policy: :fail_run
             )

    assert {:ok, :attached} = Transport.attach(port, self())
    assert :ok = Transport.send_input(port, "PING")
    assert :ok = Transport.demand(port, self(), 2)

    assert_receive {:transport_message, %{"type" => "assistant_delta", "delta" => "PING"}}
    assert_receive {:transport_message, %{"type" => "result", "stop_reason" => "end_turn"}}
    assert_receive {:transport_exit, 0, _diagnostics}
  end

  test "interrupt/1 terminates active subprocess and emits transport exit" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail
      trap 'exit 0' INT
      echo '{"type":"assistant_delta","delta":"READY"}'
      while true; do :; done
      """)

    assert {:ok, port} =
             Port.start_link(
               program: script,
               args: [],
               queue_limit: 8,
               overflow_policy: :fail_run
             )

    assert {:ok, :attached} = Transport.attach(port, self())
    assert :ok = Transport.demand(port, self(), 1)
    assert_receive {:transport_message, %{"type" => "assistant_delta", "delta" => "READY"}}, 2_000
    ref = Process.monitor(port)

    assert :ok = Transport.interrupt(port)
    assert_receive {:transport_exit, _status, _diagnostics}, 5_000
    assert_receive {:DOWN, ^ref, :process, ^port, :normal}, 1_000
  end

  test "stderr is captured separately and included in diagnostics on exit" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail

      echo '{"type":"assistant_delta","delta":"STDOUT_OK"}'
      echo "stderr-line-1" >&2
      echo "stderr-line-2" >&2
      exit 7
      """)

    assert {:ok, port} =
             Port.start_link(
               program: script,
               args: [],
               queue_limit: 8,
               overflow_policy: :fail_run
             )

    assert {:ok, :attached} = Transport.attach(port, self())
    assert :ok = Transport.demand(port, self(), 1)

    assert_receive {:transport_message, %{"type" => "assistant_delta", "delta" => "STDOUT_OK"}}
    assert_receive {:transport_exit, 7, diagnostics}
    assert Enum.any?(diagnostics, &String.contains?(&1, "stderr-line-1"))
    assert Enum.any?(diagnostics, &String.contains?(&1, "stderr-line-2"))
  end

  test "interrupt sends SIGINT and subprocess can handle it gracefully" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail

      trap 'echo "{\\"type\\":\\"assistant_delta\\",\\"delta\\":\\"INTERRUPTED\\"}"; exit 0' INT
      echo '{"type":"assistant_delta","delta":"READY"}'
      while true; do :; done
      """)

    assert {:ok, port} =
             Port.start_link(
               program: script,
               args: [],
               queue_limit: 8,
               overflow_policy: :fail_run
             )

    assert {:ok, :attached} = Transport.attach(port, self())
    assert :ok = Transport.demand(port, self(), 2)

    assert_receive {:transport_message, %{"type" => "assistant_delta", "delta" => "READY"}}, 2_000
    assert :ok = Transport.interrupt(port)

    assert_receive {:transport_message, %{"type" => "assistant_delta", "delta" => "INTERRUPTED"}},
                   5_000

    assert_receive {:transport_exit, status, _diagnostics}, 5_000
    assert status in [0, 2, 130]
  end

  test "force close sends SIGKILL after SIGTERM" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail
      trap '' TERM

      while true; do sleep 0.1; done
      """)

    assert {:ok, port} =
             Port.start_link(
               program: script,
               args: [],
               queue_limit: 8,
               overflow_policy: :fail_run
             )

    os_pid = os_pid!(port)
    assert_eventually(fn -> os_pid_alive?(os_pid) end)

    ref = Process.monitor(port)
    assert :ok = Transport.close(port)
    assert_receive {:DOWN, ^ref, :process, ^port, :normal}

    assert_eventually(fn -> not os_pid_alive?(os_pid) end)
  end

  test "subprocess exit flushes remaining buffered stdout lines" do
    line_count = 120

    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail

      count="$1"

      for n in $(seq 1 "$count"); do
        echo "{\\"type\\":\\"assistant_delta\\",\\"delta\\":\\"$n\\"}"
      done
      """)

    assert {:ok, port} =
             Port.start_link(
               program: script,
               args: ["#{line_count}"],
               queue_limit: 200,
               overflow_policy: :fail_run
             )

    assert {:ok, :attached} = Transport.attach(port, self())
    {messages, {status, _diagnostics}} = collect_until_exit([])

    assert status == 0
    assert length(messages) == line_count
    assert Enum.map(messages, & &1["delta"]) == Enum.map(1..line_count, &Integer.to_string/1)
  end

  test "health/1 returns :healthy when subprocess is alive" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail

      while true; do sleep 0.1; done
      """)

    assert {:ok, port} =
             Port.start_link(
               program: script,
               args: [],
               queue_limit: 8,
               overflow_policy: :fail_run
             )

    assert :healthy = Transport.health(port)
    exec_pid = exec_pid!(port)
    Process.exit(exec_pid, :kill)

    assert_eventually(fn ->
      case health_or_degraded(port) do
        :degraded -> true
        {:unhealthy, _reason} -> true
        _ -> false
      end
    end)
  end

  test "startup lease timeout stops unleased subprocess transport" do
    old_flag = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, old_flag) end)

    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail

      while true; do sleep 0.1; done
      """)

    assert {:ok, port} =
             Port.start_link(
               program: script,
               args: [],
               queue_limit: 8,
               overflow_policy: :fail_run,
               startup_lease_timeout_ms: 50
             )

    os_pid = os_pid!(port)
    ref = Process.monitor(port)

    assert_receive {:EXIT, ^port, {:shutdown, :startup_lease_timeout}}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^port, {:shutdown, :startup_lease_timeout}}, 2_000
    assert_eventually(fn -> not os_pid_alive?(os_pid) end)
  end

  test "attach cancels startup lease timeout" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail

      while true; do sleep 0.1; done
      """)

    assert {:ok, port} =
             Port.start_link(
               program: script,
               args: [],
               queue_limit: 8,
               overflow_policy: :fail_run,
               startup_lease_timeout_ms: 40
             )

    assert {:ok, :attached} = Transport.attach(port, self())
    Process.sleep(90)
    assert Process.alive?(port)

    assert :ok = Transport.close(port)
  end

  test "start_link fails fast when subprocess cannot be started" do
    old_flag = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, old_flag) end)

    missing_program = "/definitely/missing/program-#{System.unique_integer([:positive])}"

    result =
      Port.start_link(
        program: missing_program,
        args: [],
        queue_limit: 8,
        overflow_policy: :fail_run
      )

    assert match?({:error, {:transport_start_failed, _reason}}, result) or
             match?({:error, {{:transport_start_failed, _reason}, _child}}, result)
  end

  test "stdout buffer overflow emits transport error and recovers at next newline" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail

      awk 'BEGIN{for(i=0;i<5000;i++)printf "x"; printf "\\n"}'
      echo '{"type":"assistant_delta","delta":"AFTER"}'
      """)

    assert {:ok, port} =
             Port.start_link(
               program: script,
               args: [],
               queue_limit: 8,
               overflow_policy: :fail_run,
               max_stdout_buffer_bytes: 128
             )

    assert {:ok, :attached} = Transport.attach(port, self())
    assert :ok = Transport.demand(port, self(), 1)

    assert_receive {:transport_error, {:stdout_buffer_overflow, overflow_size}}, 2_000
    assert overflow_size > 128

    assert_receive {:transport_message, %{"type" => "assistant_delta", "delta" => "AFTER"}}, 2_000
    assert_receive {:transport_exit, 0, _diagnostics}, 2_000
  end

  test "headless timeout stops subprocess after leasee exits" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail

      while true; do sleep 0.1; done
      """)

    assert {:ok, port} =
             Port.start_link(
               program: script,
               args: [],
               queue_limit: 8,
               overflow_policy: :fail_run,
               startup_lease_timeout_ms: 2_000,
               headless_timeout_ms: 60
             )

    leasee =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, :attached} = Transport.attach(port, leasee)
    os_pid = os_pid!(port)

    send(leasee, :stop)
    assert {:ok, :normal} = wait_for_process_death(port, 2_000)
    assert_eventually(fn -> not os_pid_alive?(os_pid) end)
  end

  test "send_input/4 returns typed timeout error when transport is suspended" do
    cat = System.find_executable("cat") || "/bin/cat"
    assert {:ok, port} = Port.start_link(program: cat, args: [])

    :ok = :sys.suspend(port)

    try do
      assert {:error, %Error{kind: :timeout, domain: :transport}} =
               Transport.send_input(port, "PING", [], 20)
    after
      if Process.alive?(port) do
        :ok = :sys.resume(port)
        _ = Transport.close(port)
      end
    end
  end

  test "close/2 does not crash caller when transport is suspended" do
    cat = System.find_executable("cat") || "/bin/cat"
    assert {:ok, port} = Port.start_link(program: cat, args: [])

    :ok = :sys.suspend(port)

    try do
      assert :ok = Transport.close(port, 20)
    after
      if Process.alive?(port) do
        :ok = :sys.resume(port)
        _ = Transport.close(port)
      end
    end
  end

  test "end_input/1 sends EOF to subprocess stdin" do
    cat = System.find_executable("cat") || "/bin/cat"
    assert {:ok, port} = Port.start_link(program: cat, args: [])
    assert {:ok, :attached} = Transport.attach(port, self())

    assert :ok = Transport.send_input(port, ~s({"type":"assistant_delta","delta":"echo me"}))
    assert :ok = Transport.end_input(port)
    assert :ok = Transport.demand(port, self(), 1)

    assert_receive {:transport_message, %{"delta" => "echo me", "type" => "assistant_delta"}},
                   2_000

    assert_receive {:transport_exit, 0, _diagnostics}, 2_000
  end

  test "stderr/1 returns capped stderr tail configured at startup" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail
      printf '1234567890ABCDEFGHIJ' >&2
      sleep 0.1
      """)

    assert {:ok, port} =
             Port.start_link(
               program: script,
               args: [],
               max_stderr_buffer_bytes: 8
             )

    assert {:ok, :attached} = Transport.attach(port, self())
    Process.sleep(50)
    assert Transport.stderr(port) == "CDEFGHIJ"
    assert_receive {:transport_exit, 0, _diagnostics}, 2_000
  end

  test "send_input/end_input return typed not_connected errors after transport exits" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail
      echo '{"type":"assistant_delta","delta":"done"}'
      """)

    assert {:ok, port} = Port.start_link(program: script, args: [])
    assert {:ok, :attached} = Transport.attach(port, self())
    assert :ok = Transport.demand(port, self(), 1)
    assert_receive {:transport_message, %{"delta" => "done", "type" => "assistant_delta"}}, 2_000
    assert_receive {:transport_exit, 0, _diagnostics}, 2_000
    assert {:ok, _reason} = wait_for_process_death(port, 2_000)

    assert {:error, %Error{kind: :transport_error, domain: :transport}} =
             Transport.send_input(port, "after-exit")

    assert {:error, %Error{kind: :transport_error, domain: :transport}} =
             Transport.end_input(port)
  end

  test "finalize exit draining remains responsive under large pending queue load" do
    cat = System.find_executable("cat") || "/bin/cat"
    assert {:ok, port} = Port.start_link(program: cat, args: [], queue_limit: 200_000)
    assert {:ok, :attached} = Transport.attach(port, self())

    try do
      state = :sys.get_state(port)
      {pid, os_pid} = state.subprocess

      pending_lines =
        Enum.reduce(1..100_000, :queue.new(), fn idx, queue ->
          line = ~s({"type":"assistant_delta","delta":"#{idx}"})
          :queue.in(line, queue)
        end)

      :sys.replace_state(port, fn current ->
        %{current | pending_lines: pending_lines, stdout_buffer: "", drain_scheduled?: false}
      end)

      send(port, {:finalize_exit, os_pid, pid, :normal})

      assert {:ok, :healthy} = call_with_timeout(port, :health, 200)
    after
      if Process.alive?(port) do
        _ = Transport.close(port)
      end
    end
  end

  test "handles UTF-8 codepoint split across stdout chunks" do
    script =
      write_script!("""
      #!/usr/bin/env bash
      set -euo pipefail
      sleep 5
      """)

    assert {:ok, port} = Port.start_link(program: script, args: [])
    assert {:ok, :attached} = Transport.attach(port, self())

    try do
      state = :sys.get_state(port)
      {_exec_pid, os_pid} = state.subprocess

      line = ~s({"type":"assistant_delta","delta":"hello — world"}) <> "\n"
      {idx, _len} = :binary.match(line, <<226, 128, 148>>)
      chunk1 = :binary.part(line, 0, idx + 1)
      chunk2 = :binary.part(line, idx + 1, byte_size(line) - idx - 1)

      send(port, {:stdout, os_pid, chunk1})
      send(port, {:stdout, os_pid, chunk2})

      assert :ok = Transport.demand(port, self(), 1)

      assert_receive {:transport_message,
                      %{"delta" => "hello — world", "type" => "assistant_delta"}},
                     2_000
    after
      _ = Transport.close(port)
    end
  end

  defp assert_eventually(fun, attempts \\ 20)

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
      Path.join(System.tmp_dir!(), "asm-transport-port-#{System.unique_integer([:positive])}.sh")

    File.write!(path, contents)
    File.chmod!(path, 0o755)
    path
  end

  defp os_pid_alive?(os_pid) when is_integer(os_pid) do
    {_output, status} =
      System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)

    status == 0
  end

  defp collect_until_exit(acc) do
    receive do
      {:transport_message, raw_map} ->
        collect_until_exit([raw_map | acc])

      {:transport_exit, status, diagnostics} ->
        {Enum.reverse(acc), {status, diagnostics}}
    after
      5_000 ->
        flunk("timed out waiting for transport exit")
    end
  end

  defp health_or_degraded(pid) do
    Transport.health(pid)
  catch
    :exit, _ -> :degraded
  end

  defp exec_pid!(port) do
    state = :sys.get_state(port)

    case state.subprocess do
      {pid, _os_pid} when is_pid(pid) -> pid
      _ -> flunk("transport subprocess missing")
    end
  end

  defp os_pid!(port) do
    state = :sys.get_state(port)

    case state.subprocess do
      {_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> flunk("transport os pid missing")
    end
  end
end
