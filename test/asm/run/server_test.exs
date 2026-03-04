defmodule ASM.Run.ServerTest do
  use ExUnit.Case, async: true

  alias ASM.{Event, Message, Run}
  alias ASM.Transport.Port

  defmodule CrashOnInterruptTransport do
    @moduledoc false

    use GenServer

    def start(opts \\ []) do
      GenServer.start(__MODULE__, opts)
    end

    @impl true
    def init(_opts), do: {:ok, %{}}

    @impl true
    def handle_call({:attach, _run_pid}, _from, state) do
      {:reply, {:ok, :attached}, state}
    end

    def handle_call(:interrupt, _from, state) do
      Process.exit(self(), :kill)
      {:noreply, state}
    end

    def handle_call({:detach, _run_pid}, _from, state) do
      {:reply, :ok, state}
    end

    def handle_call(:close, _from, state) do
      {:stop, :normal, :ok, state}
    end

    @impl true
    def handle_cast({:demand, _run_pid, _n}, state) do
      {:noreply, state}
    end
  end

  defmodule SlowControlTransport do
    @moduledoc false

    use GenServer

    def start(opts \\ []) do
      GenServer.start(__MODULE__, opts)
    end

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:attach, _run_pid}, _from, state) do
      Process.sleep(Keyword.get(state, :attach_delay_ms, 0))
      {:reply, {:ok, :attached}, state}
    end

    def handle_call(:interrupt, _from, state) do
      Process.sleep(Keyword.get(state, :interrupt_delay_ms, 0))
      {:reply, :ok, state}
    end

    def handle_call({:detach, _run_pid}, _from, state) do
      {:reply, :ok, state}
    end

    def handle_call(:close, _from, state) do
      {:stop, :normal, :ok, state}
    end

    @impl true
    def handle_cast({:demand, _run_pid, _n}, state) do
      {:noreply, state}
    end
  end

  test "emits run_started event on bootstrap" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-boot",
               session_id: "session-boot",
               provider: :claude,
               subscriber: self()
             )

    assert_receive {:asm_run_event, "run-boot", %Event{kind: :run_started}}
    GenServer.stop(run_pid)
  end

  test "ingest_event updates reducer state and terminal event emits done" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-events",
               session_id: "session-events",
               provider: :claude,
               subscriber: self()
             )

    assert_receive {:asm_run_event, "run-events", %Event{kind: :run_started}}

    delta_event =
      %Event{
        id: Event.generate_id(),
        kind: :assistant_delta,
        run_id: "run-events",
        session_id: "session-events",
        payload: %Message.Partial{content_type: :text, delta: "abc"},
        timestamp: DateTime.utc_now()
      }

    assert :ok = Run.Server.ingest_event(run_pid, delta_event)
    assert_receive {:asm_run_event, "run-events", %Event{kind: :assistant_delta}}

    state = Run.Server.get_state(run_pid)
    assert state.text_acc == "abc"

    result_event =
      %Event{
        id: Event.generate_id(),
        kind: :result,
        run_id: "run-events",
        session_id: "session-events",
        payload: %Message.Result{stop_reason: :end_turn},
        timestamp: DateTime.utc_now()
      }

    ref = Process.monitor(run_pid)
    assert :ok = Run.Server.ingest_event(run_pid, result_event)
    assert_receive {:asm_run_event, "run-events", %Event{kind: :result}}
    assert_receive {:asm_run_done, "run-events"}
    assert_receive {:DOWN, ^ref, :process, ^run_pid, :normal}
  end

  test "interrupt emits done and stops run" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-int",
               session_id: "session-int",
               provider: :claude,
               subscriber: self()
             )

    assert_receive {:asm_run_event, "run-int", %Event{kind: :run_started}}

    ref = Process.monitor(run_pid)
    assert :ok = Run.Server.interrupt(run_pid)
    assert_receive {:asm_run_event, "run-int", %Event{kind: :error}}
    assert_receive {:asm_run_done, "run-int"}
    assert_receive {:DOWN, ^ref, :process, ^run_pid, :normal}
  end

  test "transport messages are parsed by run server and terminal result stops run" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-transport-parse",
               session_id: "session-transport-parse",
               provider: :claude,
               subscriber: self()
             )

    assert_receive {:asm_run_event, "run-transport-parse", %Event{kind: :run_started}}

    assert {:ok, transport_pid} = Port.start_link([])
    assert :ok = Run.Server.attach_transport(run_pid, transport_pid)

    assert :ok = Port.inject(transport_pid, %{"type" => "assistant_delta", "delta" => "abc"})
    assert :ok = Port.inject(transport_pid, %{"type" => "result", "stop_reason" => "end_turn"})

    assert_receive {:asm_run_event, "run-transport-parse", %Event{kind: :assistant_delta}}
    assert_receive {:asm_run_event, "run-transport-parse", %Event{kind: :result}}
    assert_receive {:asm_run_done, "run-transport-parse"}
  end

  test "successful transport exit without terminal payload emits run_completed" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-transport-exit-ok",
               session_id: "session-transport-exit-ok",
               provider: :claude,
               subscriber: self()
             )

    assert_receive {:asm_run_event, "run-transport-exit-ok", %Event{kind: :run_started}}

    assert {:ok, transport_pid} = Port.start_link([])
    assert :ok = Run.Server.attach_transport(run_pid, transport_pid)

    send(run_pid, {:transport_exit, 0, []})

    assert_receive {:asm_run_event, "run-transport-exit-ok", %Event{kind: :run_completed}}
    assert_receive {:asm_run_done, "run-transport-exit-ok"}
  end

  test "non-zero transport exit emits typed transport error and stops run" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-transport-exit-err",
               session_id: "session-transport-exit-err",
               provider: :claude,
               subscriber: self()
             )

    assert_receive {:asm_run_event, "run-transport-exit-err", %Event{kind: :run_started}}

    assert {:ok, transport_pid} = Port.start_link([])
    assert :ok = Run.Server.attach_transport(run_pid, transport_pid)

    send(run_pid, {:transport_exit, 2, ["error: failed"]})

    assert_receive {:asm_run_event, "run-transport-exit-err", %Event{kind: :error} = event}
    assert event.payload.kind == :transport_error
    assert event.payload.message =~ "status 2"
    assert_receive {:asm_run_done, "run-transport-exit-err"}
  end

  test "interrupt survives dead transport call exits" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-interrupt-dead-transport",
               session_id: "session-interrupt-dead-transport",
               provider: :claude,
               subscriber: self()
             )

    assert_receive {:asm_run_event, "run-interrupt-dead-transport", %Event{kind: :run_started}}

    assert {:ok, transport_pid} = CrashOnInterruptTransport.start()
    assert :ok = Run.Server.attach_transport(run_pid, transport_pid)

    ref = Process.monitor(run_pid)
    assert :ok = Run.Server.interrupt(run_pid)

    assert_receive {:asm_run_event, "run-interrupt-dead-transport", %Event{kind: :error}}
    assert_receive {:asm_run_done, "run-interrupt-dead-transport"}
    assert_receive {:DOWN, ^ref, :process, ^run_pid, :normal}
  end

  test "attach_transport respects configured transport call timeout" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-attach-timeout",
               session_id: "session-attach-timeout",
               provider: :claude,
               subscriber: self(),
               transport_call_timeout_ms: 10
             )

    assert_receive {:asm_run_event, "run-attach-timeout", %Event{kind: :run_started}}
    assert {:ok, transport_pid} = SlowControlTransport.start(attach_delay_ms: 100)

    assert {:error, %ASM.Error{} = error} = Run.Server.attach_transport(run_pid, transport_pid)
    assert error.kind == :transport_error
    assert error.message =~ "attach"
  end

  test "interrupt completes even when transport interrupt call times out" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-interrupt-timeout",
               session_id: "session-interrupt-timeout",
               provider: :claude,
               subscriber: self(),
               transport_call_timeout_ms: 10
             )

    assert_receive {:asm_run_event, "run-interrupt-timeout", %Event{kind: :run_started}}
    assert {:ok, transport_pid} = SlowControlTransport.start(interrupt_delay_ms: 100)
    assert :ok = Run.Server.attach_transport(run_pid, transport_pid)

    ref = Process.monitor(run_pid)
    assert :ok = Run.Server.interrupt(run_pid)

    assert_receive {:asm_run_event, "run-interrupt-timeout", %Event{kind: :error}}
    assert_receive {:asm_run_done, "run-interrupt-timeout"}
    assert_receive {:DOWN, ^ref, :process, ^run_pid, :normal}
  end
end
