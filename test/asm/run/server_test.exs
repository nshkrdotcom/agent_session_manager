defmodule ASM.Run.ServerTest do
  use ASM.TestCase

  alias ASM.{Error, Event, Run}
  alias ASM.Execution.Config
  alias ASM.TestSupport.FakeBackend
  alias CliSubprocessCore.Payload

  defmodule InterruptProbeBackend do
    @moduledoc false

    use GenServer

    @behaviour ASM.ProviderBackend

    alias CliSubprocessCore.Event, as: CoreEvent
    alias CliSubprocessCore.Payload

    def start_run(config) do
      GenServer.start_link(__MODULE__, config)
    end

    def send_input(_server, _input, _opts \\ []), do: :ok
    def end_input(_server), do: :ok

    def interrupt(server) do
      GenServer.call(server, :interrupt)
    end

    def close(server) do
      GenServer.stop(server, :normal)
    catch
      :exit, _ -> :ok
    end

    def subscribe(server, pid, ref) do
      GenServer.call(server, {:subscribe, pid, ref})
    end

    def info(server) do
      GenServer.call(server, :info)
    end

    @impl true
    def init(config) do
      state = %{
        provider: config.provider.name,
        subscriber: config.subscriber_pid,
        subscription_ref: config.subscription_ref,
        test_pid: Keyword.get(config.backend_opts, :test_pid)
      }

      {:ok, state, {:continue, :emit_run_started}}
    end

    @impl true
    def handle_continue(:emit_run_started, state) do
      emit_core_event(state, :run_started, Payload.RunStarted.new(command: "interrupt-probe"))
      {:noreply, state}
    end

    @impl true
    def handle_call(:interrupt, _from, state) do
      if is_pid(state.test_pid) do
        send(state.test_pid, {:backend_interrupted, self()})
      end

      {:reply, :ok, state}
    end

    def handle_call({:subscribe, pid, ref}, _from, state) do
      {:reply, :ok, %{state | subscriber: pid, subscription_ref: ref}}
    end

    def handle_call(:info, _from, state) do
      {:reply, %{backend: :interrupt_probe, provider: state.provider}, state}
    end

    defp emit_core_event(state, kind, payload) do
      if is_pid(state.subscriber) and is_reference(state.subscription_ref) do
        event = CoreEvent.new(kind, provider: state.provider, payload: payload)

        send(
          state.subscriber,
          {:cli_subprocess_core_session, state.subscription_ref, {:event, event}}
        )
      end
    end
  end

  defmodule CrashBackend do
    @moduledoc false

    use GenServer

    @behaviour ASM.ProviderBackend

    alias CliSubprocessCore.Event, as: CoreEvent
    alias CliSubprocessCore.Payload

    def start_run(config) do
      GenServer.start_link(__MODULE__, config)
    end

    def send_input(_server, _input, _opts \\ []), do: :ok
    def end_input(_server), do: :ok
    def interrupt(_server), do: :ok

    def close(server) do
      GenServer.stop(server, :normal)
    catch
      :exit, _ -> :ok
    end

    def subscribe(server, pid, ref) do
      GenServer.call(server, {:subscribe, pid, ref})
    end

    def info(server) do
      GenServer.call(server, :info)
    end

    @impl true
    def init(config) do
      state = %{
        provider: config.provider.name,
        subscriber: config.subscriber_pid,
        subscription_ref: config.subscription_ref
      }

      {:ok, state, {:continue, :emit_then_schedule_crash}}
    end

    @impl true
    def handle_continue(:emit_then_schedule_crash, state) do
      emit_core_event(state, :run_started, Payload.RunStarted.new(command: "crash-probe"))
      Process.send_after(self(), :crash, 0)
      {:noreply, state}
    end

    @impl true
    def handle_call({:subscribe, pid, ref}, _from, state) do
      {:reply, :ok, %{state | subscriber: pid, subscription_ref: ref}}
    end

    def handle_call(:info, _from, state) do
      {:reply, %{backend: :crash_probe, provider: state.provider}, state}
    end

    @impl true
    def handle_info(:crash, state) do
      {:stop, :backend_crash, state}
    end

    defp emit_core_event(state, kind, payload) do
      if is_pid(state.subscriber) and is_reference(state.subscription_ref) do
        event = CoreEvent.new(kind, provider: state.provider, payload: payload)

        send(
          state.subscriber,
          {:cli_subprocess_core_session, state.subscription_ref, {:event, event}}
        )
      end
    end
  end

  test "bootstrap consumes backend events and finishes on result" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-boot",
               session_id: "session-boot",
               provider: :claude,
               subscriber: self(),
               backend_module: FakeBackend,
               execution_config: local_execution_config()
             )

    assert_receive {:asm_run_event, "run-boot", %Event{kind: :run_started}}
    assert_receive {:asm_run_event, "run-boot", %Event{kind: :assistant_delta}}
    assert_receive {:asm_run_event, "run-boot", %Event{kind: :result}}
    assert_receive {:asm_run_done, "run-boot"}
    assert {:ok, :normal} = wait_for_process_death(run_pid, 2_000)
  end

  test "ingest_event updates reducer state and terminal event emits done" do
    script = [
      {:core, :run_started, Payload.RunStarted.new(command: "fake")}
    ]

    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-events",
               session_id: "session-events",
               provider: :claude,
               subscriber: self(),
               backend_module: FakeBackend,
               backend_opts: [script: script],
               execution_config: local_execution_config()
             )

    assert_receive {:asm_run_event, "run-events", %Event{kind: :run_started}}

    delta_event =
      Event.new(
        :assistant_delta,
        Payload.AssistantDelta.new(content: "abc"),
        run_id: "run-events",
        session_id: "session-events",
        provider: :claude,
        timestamp: DateTime.utc_now()
      )

    assert :ok = Run.Server.ingest_event(run_pid, delta_event)
    assert_receive {:asm_run_event, "run-events", %Event{kind: :assistant_delta}}

    state = Run.Server.get_state(run_pid)
    assert state.status == :running
    assert state.text_acc == "abc"

    result_event =
      Event.new(
        :result,
        Payload.Result.new(status: :completed, stop_reason: :end_turn),
        run_id: "run-events",
        session_id: "session-events",
        provider: :claude,
        timestamp: DateTime.utc_now()
      )

    ref = Process.monitor(run_pid)
    assert :ok = Run.Server.ingest_event(run_pid, result_event)
    assert_receive {:asm_run_event, "run-events", %Event{kind: :result}}
    assert_receive {:asm_run_done, "run-events"}
    assert_receive {:DOWN, ^ref, :process, ^run_pid, :normal}
  end

  test "interrupt calls backend interrupt and emits terminal error" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-int",
               session_id: "session-int",
               provider: :claude,
               subscriber: self(),
               backend_module: InterruptProbeBackend,
               backend_opts: [test_pid: self()],
               execution_config: local_execution_config()
             )

    assert_receive {:asm_run_event, "run-int", %Event{kind: :run_started}}

    ref = Process.monitor(run_pid)
    assert :ok = Run.Server.interrupt(run_pid)
    assert_receive {:backend_interrupted, _backend_pid}
    assert_receive {:asm_run_event, "run-int", %Event{kind: :error} = event}
    assert Event.legacy_payload(event).kind == :user_cancelled
    assert_receive {:asm_run_done, "run-int"}
    assert_receive {:DOWN, ^ref, :process, ^run_pid, :normal}
  end

  test "backend crash surfaces terminal error and stops run" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-crash",
               session_id: "session-crash",
               provider: :claude,
               subscriber: self(),
               backend_module: CrashBackend,
               execution_config: local_execution_config()
             )

    assert_receive {:asm_run_event, "run-crash", %Event{kind: :run_started}}
    assert_receive {:asm_run_event, "run-crash", %Event{kind: :error} = event}
    assert Event.legacy_payload(event).kind == :transport_error
    assert_receive {:asm_run_done, "run-crash"}
    assert {:ok, :normal} = wait_for_process_death(run_pid, 2_000)
  end

  test "attach_transport/2 returns explicit config error in backend runtime" do
    assert {:error, %Error{} = error} = Run.Server.attach_transport(self(), self())
    assert error.kind == :config_invalid
    assert error.message =~ "unavailable"
  end

  defp local_execution_config do
    %Config{execution_mode: :local, transport_call_timeout_ms: 1_000}
  end
end
