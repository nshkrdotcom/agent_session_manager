defmodule ASM.Session.ServerTest do
  use ASM.TestCase

  alias ASM.Control
  alias ASM.Execution.Config
  alias ASM.Session.Server
  alias ASM.Session.Supervisor, as: SessionSupervisor
  alias ASM.TestSupport.FakeBackend
  alias CliSubprocessCore.Payload

  defmodule RunProbe do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      run_id = Keyword.fetch!(opts, :run_id)
      send(test_pid, {:run_started, run_id, self()})

      send(
        test_pid,
        {:run_boot_opts, run_id, Keyword.take(opts, [:continuation, :intervention_for_run_id])}
      )

      {:ok, %{test_pid: test_pid, run_id: run_id}}
    end

    @impl true
    def handle_cast({:resolve_approval, approval_id, decision}, state) do
      send(state.test_pid, {:approval_resolved, state.run_id, approval_id, decision})
      {:noreply, state}
    end

    @impl true
    def handle_cast(:interrupt, state) do
      send(state.test_pid, {:run_interrupted, state.run_id})
      {:stop, :normal, state}
    end

    @impl true
    def handle_cast(:stop, state) do
      {:stop, :normal, state}
    end
  end

  defmodule FailingRunProbe do
    @moduledoc false
    use GenServer

    def start_link(_opts) do
      {:error, ASM.Error.new(:cli_not_found, :provider, "run bootstrap failed")}
    end

    @impl true
    def init(state), do: {:ok, state}
  end

  test "submit_run/3 starts active run under capacity" do
    %{server: server, session_id: session_id} = start_session!(provider: :claude)

    assert {:ok, run_id, run_pid} =
             Server.submit_run(server, "hello",
               run_module: RunProbe,
               run_module_opts: [test_pid: self()]
             )

    assert_receive {:run_started, ^run_id, ^run_pid}

    state = Server.get_state(server)
    assert state.active_runs[run_id] == run_pid

    assert :ok = SessionSupervisor.stop_session(session_id)
  end

  test "submit_run/3 queues when provider profile capacity is reached" do
    %{server: server, session_id: session_id} = start_session!(provider: :claude)

    assert {:ok, run_id1, _run_pid1} =
             Server.submit_run(server, "r1",
               run_module: RunProbe,
               run_module_opts: [test_pid: self()]
             )

    assert_receive {:run_started, ^run_id1, _}

    assert {:ok, run_id2, :queued} =
             Server.submit_run(server, "r2",
               run_module: RunProbe,
               run_module_opts: [test_pid: self()]
             )

    state = Server.get_state(server)
    assert map_size(state.active_runs) == 1
    assert :queue.len(state.run_queue) == 1
    assert run_id2 not in Map.keys(state.active_runs)

    assert :ok = SessionSupervisor.stop_session(session_id)
  end

  test "cancel_run/2 removes queued run" do
    %{server: server, session_id: session_id} = start_session!(provider: :claude)

    assert {:ok, run_id1, _run_pid1} =
             Server.submit_run(server, "r1",
               run_module: RunProbe,
               run_module_opts: [test_pid: self()]
             )

    assert_receive {:run_started, ^run_id1, _}

    assert {:ok, run_id2, :queued} =
             Server.submit_run(server, "r2",
               run_module: RunProbe,
               run_module_opts: [test_pid: self()]
             )

    assert :ok = Server.cancel_run(server, run_id2)

    state = Server.get_state(server)
    assert :queue.len(state.run_queue) == 0

    assert :ok = SessionSupervisor.stop_session(session_id)
  end

  test "resolve_approval/3 routes decision and clears pending index" do
    %{server: server, session_id: session_id} = start_session!(provider: :claude)

    assert {:ok, run_id, run_pid} =
             Server.submit_run(server, "approval",
               run_module: RunProbe,
               run_module_opts: [test_pid: self()]
             )

    assert_receive {:run_started, ^run_id, ^run_pid}

    send(
      server,
      {:register_approval, run_pid,
       %Control.ApprovalRequest{
         approval_id: "approval-1",
         tool_name: "bash",
         tool_input: %{"cmd" => "ls"}
       }}
    )

    assert :ok = Server.resolve_approval(server, "approval-1", :allow)

    assert_receive {:approval_resolved, ^run_id, "approval-1", :allow}

    state = Server.get_state(server)
    refute Map.has_key?(state.pending_approval_index, "approval-1")

    assert :ok = SessionSupervisor.stop_session(session_id)
  end

  test "pause_run/2 interrupts the active run" do
    %{server: server, session_id: session_id} = start_session!(provider: :claude)

    assert {:ok, run_id, run_pid} =
             Server.submit_run(server, "pause-me",
               run_module: RunProbe,
               run_module_opts: [test_pid: self()]
             )

    assert_receive {:run_started, ^run_id, ^run_pid}
    assert_receive {:run_boot_opts, ^run_id, _opts}

    assert :ok = Server.pause_run(server, run_id)
    assert_receive {:run_interrupted, ^run_id}

    assert :ok = SessionSupervisor.stop_session(session_id)
  end

  test "checkpoint/1 returns the latest captured provider session checkpoint" do
    %{server: server, session_id: session_id} = start_session!(provider: :claude)

    send(
      server,
      {:capture_checkpoint, "run-checkpoint", "claude-session-123",
       %{phase: :resume_ready, provider_session_id: "claude-session-123"}}
    )

    assert_eventually(fn ->
      assert {:ok, checkpoint} = Server.checkpoint(server)
      checkpoint != nil
    end)

    assert {:ok, checkpoint} = Server.checkpoint(server)
    assert checkpoint.run_id == "run-checkpoint"
    assert checkpoint.provider_session_id == "claude-session-123"
    assert checkpoint.metadata.phase == :resume_ready

    assert :ok = SessionSupervisor.stop_session(session_id)
  end

  test "resume_run/3 starts a continuation-backed run from the stored checkpoint" do
    %{server: server, session_id: session_id} = start_session!(provider: :claude)

    send(
      server,
      {:capture_checkpoint, "run-checkpoint", "claude-session-continue", %{phase: :resume_ready}}
    )

    assert_eventually(fn ->
      match?({:ok, %{provider_session_id: "claude-session-continue"}}, Server.checkpoint(server))
    end)

    assert {:ok, run_id, run_pid} =
             Server.resume_run(server, "Continue",
               run_module: RunProbe,
               run_module_opts: [test_pid: self()]
             )

    assert_receive {:run_started, ^run_id, ^run_pid}

    assert_receive {:run_boot_opts, ^run_id,
                    [
                      continuation: %{
                        strategy: :exact,
                        provider_session_id: "claude-session-continue"
                      }
                    ]}

    assert :ok = SessionSupervisor.stop_session(session_id)
  end

  test "intervene/4 interrupts the active run and queues the resumed continuation" do
    %{server: server, session_id: session_id} = start_session!(provider: :claude)

    assert {:ok, run_id, run_pid} =
             Server.submit_run(server, "draft",
               run_module: RunProbe,
               run_module_opts: [test_pid: self()]
             )

    assert_receive {:run_started, ^run_id, ^run_pid}
    assert_receive {:run_boot_opts, ^run_id, _opts}

    send(
      server,
      {:capture_checkpoint, run_id, "claude-session-intervene", %{phase: :intervention_ready}}
    )

    assert_eventually(fn ->
      match?({:ok, %{provider_session_id: "claude-session-intervene"}}, Server.checkpoint(server))
    end)

    assert {:ok, resumed_run_id, :queued} =
             Server.intervene(server, run_id, "Continue",
               run_module: RunProbe,
               run_module_opts: [test_pid: self()]
             )

    assert_receive {:run_interrupted, ^run_id}
    assert_receive {:run_started, ^resumed_run_id, resumed_run_pid}
    assert is_pid(resumed_run_pid)

    assert_receive {:run_boot_opts, ^resumed_run_id, boot_opts}

    assert boot_opts[:continuation] == %{
             strategy: :exact,
             provider_session_id: "claude-session-intervene"
           }

    assert boot_opts[:intervention_for_run_id] == run_id

    assert :ok = SessionSupervisor.stop_session(session_id)
  end

  test "run exit promotes next queued run" do
    %{server: server, session_id: session_id} = start_session!(provider: :claude)

    assert {:ok, run_id1, run_pid1} =
             Server.submit_run(server, "r1",
               run_module: RunProbe,
               run_module_opts: [test_pid: self()]
             )

    assert_receive {:run_started, ^run_id1, ^run_pid1}

    assert {:ok, run_id2, :queued} =
             Server.submit_run(server, "r2",
               run_module: RunProbe,
               run_module_opts: [test_pid: self()]
             )

    GenServer.cast(run_pid1, :stop)

    assert_receive {:run_started, ^run_id2, run_pid2}
    assert is_pid(run_pid2)

    state = Server.get_state(server)
    assert state.active_runs[run_id2] == run_pid2
    assert :queue.len(state.run_queue) == 0

    assert :ok = SessionSupervisor.stop_session(session_id)
  end

  test "queued run bootstrap failures emit terminal error and next queued run still starts" do
    %{server: server, session_id: session_id} = start_session!(provider: :claude)

    assert {:ok, run_id1, run_pid1} =
             Server.submit_run(server, "r1",
               run_module: RunProbe,
               run_module_opts: [test_pid: self()]
             )

    assert_receive {:run_started, ^run_id1, ^run_pid1}

    assert {:ok, failed_run_id, :queued} =
             Server.submit_run(server, "r2",
               run_module: FailingRunProbe,
               run_module_opts: [subscriber: self()]
             )

    assert {:ok, run_id3, :queued} =
             Server.submit_run(server, "r3",
               run_module: RunProbe,
               run_module_opts: [test_pid: self()]
             )

    GenServer.cast(run_pid1, :stop)

    assert_receive {:asm_run_event, ^failed_run_id, %ASM.Event{kind: :error} = event}
    assert ASM.Event.legacy_payload(event).kind == :cli_not_found
    assert_receive {:asm_run_done, ^failed_run_id}
    assert_receive {:run_started, ^run_id3, run_pid3}
    assert is_pid(run_pid3)

    state = Server.get_state(server)
    assert state.active_runs[run_id3] == run_pid3
    refute Map.has_key?(state.active_runs, failed_run_id)
    assert :queue.len(state.run_queue) == 0

    assert :ok = SessionSupervisor.stop_session(session_id)
  end

  test "approval timeout clears session approval index and stale resolution returns error" do
    %{server: server, session_id: session_id} = start_session!(provider: :claude)

    script = [
      {:core, :run_started, Payload.RunStarted.new(command: "fake")}
    ]

    assert {:ok, run_id, run_pid} =
             Server.submit_run(server, "approval-timeout",
               run_module: ASM.Run.Server,
               lane: :sdk,
               backend_module: FakeBackend,
               backend_opts: [script: script],
               execution_config: local_execution_config(),
               run_module_opts: [subscriber: self(), approval_timeout_ms: 20]
             )

    assert_receive {:asm_run_event, ^run_id, %ASM.Event{kind: :run_started}}

    run_state = ASM.Run.Server.get_state(run_pid)
    assert run_state.lane == :sdk
    assert run_state.metadata.requested_lane == :sdk

    approval_id = "approval-timeout-session-1"

    assert :ok =
             ASM.Run.Server.ingest_event(
               run_pid,
               ASM.Event.new(
                 :approval_requested,
                 Payload.ApprovalRequested.new(
                   approval_id: approval_id,
                   subject: "bash",
                   details: %{"tool_input" => %{"cmd" => "ls"}}
                 ),
                 run_id: run_id,
                 session_id: session_id,
                 provider: :claude,
                 timestamp: DateTime.utc_now()
               )
             )

    assert_receive {:asm_run_event, ^run_id, %ASM.Event{kind: :approval_resolved} = event}

    assert %ASM.Control.ApprovalResolution{approval_id: ^approval_id, decision: :deny} =
             ASM.Event.legacy_payload(event)

    assert ASM.Event.legacy_payload(event).reason == "timeout"

    assert_eventually(fn ->
      state = Server.get_state(server)
      not Map.has_key?(state.pending_approval_index, approval_id)
    end)

    assert {:error, error} = Server.resolve_approval(server, approval_id, :allow)
    assert error.kind == :unknown
    assert error.domain == :approval

    assert :ok = SessionSupervisor.stop_session(session_id)
  end

  defp start_session!(opts) do
    session_id = "session-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _subtree_pid} =
             SessionSupervisor.start_session(Keyword.put(opts, :session_id, session_id))

    assert {:ok, server_pid} = lookup(session_id, :server)

    %{session_id: session_id, server: server_pid}
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

  defp local_execution_config do
    %Config{execution_mode: :local, transport_call_timeout_ms: 1_000}
  end
end
