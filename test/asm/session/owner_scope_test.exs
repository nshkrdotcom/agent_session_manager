defmodule ASM.Session.OwnerScopeTest do
  use ASM.TestCase

  alias ASM.Session
  alias ASM.TestSupport.FakeBackend
  alias CliSubprocessCore.Payload.RunStarted

  @silent_script [{:core, :run_started, RunStarted.new(command: "fake")}]

  test "an untrappably killed one-shot caller takes the whole session subtree with it" do
    session_id = "owner-scope-" <> Integer.to_string(System.unique_integer([:positive]))
    test_pid = self()

    caller =
      spawn(fn ->
        ASM.query(:claude, "hello",
          session_id: session_id,
          backend_module: FakeBackend,
          backend_opts: [script: @silent_script],
          metadata: %{test_pid: test_pid},
          stream_timeout_ms: 30_000,
          run_deadline_ms: 30_000
        )
      end)

    # The run is live before we kill anything.
    assert_receive {:fake_backend_started, backend_pid}, 2_000

    subtree_pid = await_registered(session_id, :subtree)
    server_pid = await_registered(session_id, :server)

    subtree_ref = Process.monitor(subtree_pid)
    server_ref = Process.monitor(server_pid)
    backend_ref = Process.monitor(backend_pid)
    caller_ref = Process.monitor(caller)

    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 2_000

    assert_receive {:DOWN, ^subtree_ref, :process, ^subtree_pid, _}, 2_000
    assert_receive {:DOWN, ^server_ref, :process, ^server_pid, _}, 2_000
    assert_receive {:DOWN, ^backend_ref, :process, ^backend_pid, _}, 2_000

    # Registry unregistration is the Registry's own monitor cleanup, which can
    # land after ours; the bounded wait fails hard rather than assuming it.
    assert await_unregistered(session_id, :server)
    assert await_unregistered(session_id, :subtree)
    refute session_id in Session.Supervisor.list_sessions()
  end

  test "an owned session started directly is stopped when its owner dies" do
    session_id = "owner-scope-direct-" <> Integer.to_string(System.unique_integer([:positive]))
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, _session} =
          ASM.start_session(session_id: session_id, provider: :claude, owner: self())

        send(test_pid, {:owner_ready, self()})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:owner_ready, ^owner}, 2_000

    subtree_pid = await_registered(session_id, :subtree)
    subtree_ref = Process.monitor(subtree_pid)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^subtree_ref, :process, ^subtree_pid, _}, 2_000
    assert await_unregistered(session_id, :subtree)
    refute session_id in Session.Supervisor.list_sessions()
  end

  test "an unowned session outlives the process that started it" do
    session_id = "owner-scope-unowned-" <> Integer.to_string(System.unique_integer([:positive]))
    test_pid = self()

    starter =
      spawn(fn ->
        {:ok, _session} = ASM.start_session(session_id: session_id, provider: :claude)
        send(test_pid, {:started, self()})
      end)

    assert_receive {:started, ^starter}, 2_000

    subtree_pid = await_registered(session_id, :subtree)
    on_exit(fn -> _ = ASM.stop_session(session_id) end)

    starter_ref = Process.monitor(starter)
    assert_receive {:DOWN, ^starter_ref, :process, ^starter, _}, 2_000

    assert Process.alive?(subtree_pid)
    assert session_id in Session.Supervisor.list_sessions()
  end

  test ":owner never leaks into session options" do
    session_id = "owner-scope-opts-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, session} =
             ASM.start_session(session_id: session_id, provider: :claude, owner: self())

    assert {:ok, info} = ASM.session_info(session)
    refute Keyword.has_key?(info.options, :owner)
  end

  test "stopping an already owner-collected session is an honest not_found, never an exit" do
    session_id = "owner-scope-gone-" <> Integer.to_string(System.unique_integer([:positive]))
    test_pid = self()

    owner =
      spawn(fn ->
        {:ok, session} =
          ASM.start_session(session_id: session_id, provider: :claude, owner: self())

        send(test_pid, {:owner_ready, self(), session})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:owner_ready, ^owner, session}, 2_000

    subtree_pid = await_registered(session_id, :subtree)
    subtree_ref = Process.monitor(subtree_pid)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^subtree_ref, :process, ^subtree_pid, _}, 2_000

    assert ASM.session_id(session) == nil
    assert ASM.stop_session(session) == {:error, :not_found}
  end

  defp await_unregistered(session_id, role, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await_unregistered(session_id, role, deadline)
  end

  defp do_await_unregistered(session_id, role, deadline) do
    cond do
      Registry.lookup(:asm_sessions, {session_id, role}) == [] ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("#{inspect(role)} for session #{session_id} stayed registered")

      true ->
        do_await_unregistered(session_id, role, deadline)
    end
  end

  defp await_registered(session_id, role, deadline_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await_registered(session_id, role, deadline)
  end

  defp do_await_registered(session_id, role, deadline) do
    case Registry.lookup(:asm_sessions, {session_id, role}) do
      [{pid, _}] ->
        pid

      [] ->
        if System.monotonic_time(:millisecond) >= deadline do
          flunk("#{inspect(role)} for session #{session_id} was never registered")
        else
          do_await_registered(session_id, role, deadline)
        end
    end
  end
end
