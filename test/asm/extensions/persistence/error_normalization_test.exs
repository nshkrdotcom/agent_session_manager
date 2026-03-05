defmodule ASM.Extensions.Persistence.ErrorNormalizationTest do
  use ASM.TestCase

  alias ASM.{Control, Error, Event, Store}
  alias ASM.Extensions.Persistence

  setup do
    {:ok, store} =
      __MODULE__.MalformedStore.start_link(
        append_reply: {:error, :append_invalid},
        list_reply: {:error, :list_invalid},
        reset_reply: {:error, :reset_invalid}
      )

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store)
    end)

    {:ok, store: store}
  end

  test "append_event/2 normalizes malformed store failures into ASM.Error", %{store: store} do
    assert {:error, %Error{} = error} = Persistence.append_event(store, event("evt-malformed-1"))
    assert error.kind == :unknown
    assert error.domain == :runtime
    assert error.message == "append_event/2 failed"
    assert error.cause == {:error, :append_invalid}
  end

  test "list_events/2 normalizes malformed store failures into ASM.Error", %{store: store} do
    assert {:error, %Error{} = error} = Persistence.list_events(store, "session-ext-malformed")
    assert error.kind == :unknown
    assert error.domain == :runtime
    assert error.message == "list_events/2 failed"
    assert error.cause == {:error, :list_invalid}
  end

  test "reset_session/2 normalizes malformed store failures into ASM.Error", %{store: store} do
    assert {:error, %Error{} = error} = Persistence.reset_session(store, "session-ext-malformed")
    assert error.kind == :unknown
    assert error.domain == :runtime
    assert error.message == "reset_session/2 failed"
    assert error.cause == {:error, :reset_invalid}
  end

  test "replay_session/4 keeps malformed store failures as the root cause", %{store: store} do
    assert {:error, %Error{} = error} =
             Persistence.replay_session(store, "session-ext-malformed", 0, fn acc, _event ->
               acc + 1
             end)

    assert error.kind == :unknown
    assert error.domain == :runtime
    assert error.message == "replay_session/4 failed"
    assert error.cause == {:error, :list_invalid}
  end

  test "rebuild_run/3 keeps malformed store failures as the root cause", %{store: store} do
    assert {:error, %Error{} = error} =
             Persistence.rebuild_run(store, "session-ext-malformed", "run-ext-malformed")

    assert error.kind == :unknown
    assert error.domain == :runtime
    assert error.message == "rebuild_run/3 failed"
    assert error.cause == {:error, :list_invalid}
  end

  defp event(id) do
    %Event{
      id: id,
      kind: :run_started,
      run_id: "run-ext-malformed",
      session_id: "session-ext-malformed",
      provider: :claude,
      payload: %Control.RunLifecycle{status: :started, summary: %{}},
      timestamp: DateTime.utc_now()
    }
  end

  defmodule MalformedStore do
    use GenServer

    @behaviour Store

    @impl true
    def append_event(store, event), do: Store.append_event(store, event)

    @impl true
    def list_events(store, session_id), do: Store.list_events(store, session_id)

    @impl true
    def reset_session(store, session_id), do: Store.reset_session(store, session_id)

    @spec start_link(keyword()) :: GenServer.on_start()
    def start_link(opts) when is_list(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      {:ok,
       %{
         append_reply: Keyword.fetch!(opts, :append_reply),
         list_reply: Keyword.fetch!(opts, :list_reply),
         reset_reply: Keyword.fetch!(opts, :reset_reply)
       }}
    end

    @impl true
    def handle_call({:append_event, _event}, _from, state) do
      {:reply, state.append_reply, state}
    end

    def handle_call({:list_events, _session_id}, _from, state) do
      {:reply, state.list_reply, state}
    end

    def handle_call({:reset_session, _session_id}, _from, state) do
      {:reply, state.reset_reply, state}
    end
  end
end
