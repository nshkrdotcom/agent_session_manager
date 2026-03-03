defmodule ASM.Transport.PortTest do
  use ExUnit.Case, async: true

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
end
