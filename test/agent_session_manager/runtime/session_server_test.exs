defmodule AgentSessionManager.Runtime.SessionServerTest do
  use AgentSessionManager.SupertesterCase, async: true

  alias AgentSessionManager.Concurrency.ConcurrencyLimiter
  alias AgentSessionManager.Runtime.SessionServer

  defmodule BlockingTestAdapter do
    @moduledoc false

    @behaviour AgentSessionManager.Ports.ProviderAdapter

    use GenServer

    alias AgentSessionManager.Core.{Capability, Error}

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def allow(adapter, run_id) do
      GenServer.cast(adapter, {:allow, run_id})
    end

    @impl GenServer
    def init(opts) do
      {:ok,
       %{
         test_pid: Keyword.fetch!(opts, :test_pid),
         allowed: MapSet.new(),
         pending: %{},
         capabilities: [
           %Capability{name: "chat", type: :tool, enabled: true},
           %Capability{name: "streaming", type: :sampling, enabled: true}
         ]
       }}
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def name(_), do: "blocking_test"

    @impl AgentSessionManager.Ports.ProviderAdapter
    def capabilities(adapter), do: GenServer.call(adapter, :capabilities)

    @impl AgentSessionManager.Ports.ProviderAdapter
    def execute(adapter, run, session, opts \\ []) do
      GenServer.call(adapter, {:execute, run, session, opts}, :infinity)
    end

    @impl AgentSessionManager.Ports.ProviderAdapter
    def cancel(_adapter, run_id), do: {:ok, run_id}

    @impl AgentSessionManager.Ports.ProviderAdapter
    def validate_config(_, _), do: :ok

    @impl GenServer
    def handle_call(:capabilities, _from, state) do
      {:reply, {:ok, state.capabilities}, state}
    end

    def handle_call(:name, _from, state) do
      {:reply, "blocking_test", state}
    end

    def handle_call({:execute, run, _session, opts}, from, state) do
      send(state.test_pid, {:adapter_execute_called, run.id})

      if MapSet.member?(state.allowed, run.id) do
        {:reply, execute_now(run, opts), state}
      else
        pending = Map.put(state.pending, run.id, {from, run, opts})
        {:noreply, %{state | pending: pending}}
      end
    end

    @impl GenServer
    def handle_cast({:allow, run_id}, state) do
      state = %{state | allowed: MapSet.put(state.allowed, run_id)}

      case Map.pop(state.pending, run_id) do
        {nil, pending} ->
          {:noreply, %{state | pending: pending}}

        {{from, run, opts}, pending} ->
          GenServer.reply(from, execute_now(run, opts))
          {:noreply, %{state | pending: pending}}
      end
    end

    defp execute_now(run, opts) do
      event_callback = Keyword.get(opts, :event_callback)
      timestamp = DateTime.utc_now()

      if is_function(event_callback, 1) do
        event_callback.(%{
          type: :run_started,
          session_id: run.session_id,
          run_id: run.id,
          data: %{},
          timestamp: timestamp
        })

        event_callback.(%{
          type: :message_received,
          session_id: run.session_id,
          run_id: run.id,
          data: %{content: "ok"},
          timestamp: timestamp
        })

        event_callback.(%{
          type: :run_completed,
          session_id: run.session_id,
          run_id: run.id,
          data: %{},
          timestamp: timestamp
        })
      end

      {:ok, %{output: %{content: "ok"}, token_usage: %{}, events: []}}
    rescue
      error ->
        {:error, Error.new(:internal_error, "Adapter failed: #{Exception.message(error)}")}
    end
  end

  setup ctx do
    {:ok, store} = InMemorySessionStore.start_link([])
    {:ok, adapter} = BlockingTestAdapter.start_link(test_pid: self())

    cleanup_on_exit(fn -> safe_stop(store) end)
    cleanup_on_exit(fn -> safe_stop(adapter) end)

    ctx
    |> Map.put(:store, store)
    |> Map.put(:adapter, adapter)
  end

  describe "start_link/1" do
    test "rejects max_concurrent_runs < 1", %{store: store, adapter: adapter} do
      assert {:error, %Error{code: :validation_error}} =
               SessionServer.start_link(
                 store: store,
                 adapter: adapter,
                 session_opts: %{agent_id: "agent"},
                 max_concurrent_runs: 0
               )
    end

    test "accepts max_concurrent_runs > 1 in Phase 2", %{store: store, adapter: adapter} do
      assert {:ok, server} =
               SessionServer.start_link(
                 store: store,
                 adapter: adapter,
                 session_opts: %{agent_id: "agent"},
                 max_concurrent_runs: 2
               )

      cleanup_on_exit(fn -> safe_stop(server) end)
    end
  end

  describe "submit_run/3 and strict sequential execution" do
    test "executes queued runs strictly one at a time in FIFO order", %{
      store: store,
      adapter: adapter
    } do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1,
          max_queued_runs: 10
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert {:ok, run2} = SessionServer.submit_run(server, %{prompt: "two"}, [])

      assert_receive {:adapter_execute_called, ^run1}, 1_000
      refute_receive {:adapter_execute_called, ^run2}, 200

      BlockingTestAdapter.allow(adapter, run1)
      assert {:ok, _} = SessionServer.await_run(server, run1, 2_000)

      assert_receive {:adapter_execute_called, ^run2}, 1_000
      BlockingTestAdapter.allow(adapter, run2)
      assert {:ok, _} = SessionServer.await_run(server, run2, 2_000)
    end

    test "execute_run/3 submits then awaits", %{store: store, adapter: adapter} do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      task =
        Task.async(fn -> SessionServer.execute_run(server, %{prompt: "hi"}, timeout: 5_000) end)

      assert_receive {:adapter_execute_called, run_id}, 1_000
      BlockingTestAdapter.allow(adapter, run_id)

      assert {:ok, %{output: %{content: "ok"}}} = Task.await(task, 6_000)
    end
  end

  describe "cancel_run/2" do
    test "cancels a queued run without executing it", %{store: store, adapter: adapter} do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run1} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert {:ok, run2} = SessionServer.submit_run(server, %{prompt: "two"}, [])

      assert_receive {:adapter_execute_called, ^run1}, 1_000

      assert :ok = SessionServer.cancel_run(server, run2)

      # Complete run1; run2 must never execute.
      BlockingTestAdapter.allow(adapter, run1)
      assert {:ok, _} = SessionServer.await_run(server, run1, 2_000)

      refute_receive {:adapter_execute_called, ^run2}, 300

      assert {:error, %Error{code: :cancelled}} = SessionServer.await_run(server, run2, 2_000)

      {:ok, cancelled_run} = SessionStore.get_run(store, run2)
      assert cancelled_run.status == :cancelled
    end
  end

  describe "subscribe/2" do
    test "fans out stored events with filtering options", %{store: store, adapter: adapter} do
      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run_id} = SessionServer.submit_run(server, %{prompt: "one"}, [])

      status = SessionServer.status(server)
      assert is_binary(status.session_id)

      assert {:ok, sub_ref} =
               SessionServer.subscribe(server,
                 from_sequence: 0,
                 run_id: run_id,
                 type: :message_received
               )

      assert is_reference(sub_ref)

      assert_receive {:adapter_execute_called, ^run_id}, 1_000
      BlockingTestAdapter.allow(adapter, run_id)
      assert {:ok, _} = SessionServer.await_run(server, run_id, 2_000)

      assert_receive {:session_event, session_id, %Event{} = event}, 2_000
      assert session_id == status.session_id
      assert event.type == :message_received
      assert event.run_id == run_id
      assert is_integer(event.sequence_number)
    end
  end

  describe "limiter integration" do
    test "acquires a run slot before execution and releases after completion", %{
      store: store,
      adapter: adapter
    } do
      {:ok, limiter} =
        ConcurrencyLimiter.start_link(max_parallel_sessions: 10, max_parallel_runs: 1)

      cleanup_on_exit(fn -> safe_stop(limiter) end)

      {:ok, server} =
        SessionServer.start_link(
          store: store,
          adapter: adapter,
          session_opts: %{agent_id: "agent"},
          max_concurrent_runs: 1,
          limiter: limiter
        )

      cleanup_on_exit(fn -> safe_stop(server) end)

      assert {:ok, run_id} = SessionServer.submit_run(server, %{prompt: "one"}, [])
      assert_receive {:adapter_execute_called, ^run_id}, 1_000

      assert ConcurrencyLimiter.get_status(limiter).active_runs == 1

      BlockingTestAdapter.allow(adapter, run_id)
      assert {:ok, _} = SessionServer.await_run(server, run_id, 2_000)

      assert ConcurrencyLimiter.get_status(limiter).active_runs == 0
    end
  end
end
