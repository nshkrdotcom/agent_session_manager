defmodule ASM.StreamTest do
  use ASM.TestCase

  alias ASM.{Content, Event, Message, Stream}

  defmodule DelayedDriver do
    @moduledoc false

    alias ASM.{Event, Message, Run}

    @spec start(map()) :: {:ok, pid()}
    def start(%{} = context) do
      {:ok, spawn(fn -> emit(context) end)}
    end

    defp emit(context) do
      if test_pid = Keyword.get(context.driver_opts, :test_pid) do
        send(test_pid, {:driver_started, context.run_id})
      end

      delay_ms = Keyword.get(context.driver_opts, :delay_ms, 0)
      if delay_ms > 0, do: Process.sleep(delay_ms)

      text = Keyword.get(context.driver_opts, :text, context.prompt)

      Run.Server.ingest_event(
        context.run_pid,
        %Event{
          id: Event.generate_id(),
          kind: :assistant_delta,
          run_id: context.run_id,
          session_id: context.session_id,
          provider: context.provider,
          payload: %Message.Partial{content_type: :text, delta: text},
          timestamp: DateTime.utc_now()
        }
      )

      Run.Server.ingest_event(
        context.run_pid,
        %Event{
          id: Event.generate_id(),
          kind: :result,
          run_id: context.run_id,
          session_id: context.session_id,
          provider: context.provider,
          payload: %Message.Result{stop_reason: :end_turn},
          timestamp: DateTime.utc_now()
        }
      )
    end
  end

  defmodule CrashDriver do
    @moduledoc false

    @spec start(map()) :: {:ok, pid()}
    def start(%{} = _context) do
      {:ok,
       spawn(fn ->
         Process.sleep(5)
         exit(:driver_crashed)
       end)}
    end
  end

  test "create/3 emits normalized run events and final_result/1 projects text" do
    session_id = "stream-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    events =
      ASM.stream(session, "hello", driver: ASM.TestSupport.StreamScriptedDriver)
      |> Enum.to_list()

    assert Enum.any?(events, &(&1.kind == :run_started))
    assert Enum.any?(events, &(&1.kind == :assistant_delta))
    assert Enum.any?(events, &(&1.kind == :result))

    result = Stream.final_result(events)
    assert result.session_id == session_id
    assert result.text == "hello from scripted driver"

    assert :ok = ASM.stop_session(session)
  end

  test "queue wait does not consume active stream timeout budget" do
    session_id = "stream-queue-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)
    parent = self()

    task =
      Task.async(fn ->
        ASM.stream(session, "first",
          driver: DelayedDriver,
          driver_opts: [test_pid: parent, delay_ms: 120]
        )
        |> Enum.to_list()
      end)

    assert_receive {:driver_started, _run_id}

    events =
      ASM.stream(session, "second",
        driver: DelayedDriver,
        stream_timeout_ms: 30,
        driver_opts: [text: "queued-ok"]
      )
      |> Enum.to_list()

    assert Stream.final_result(events).text == "queued-ok"

    _ = Task.shutdown(task, 500)
    _ = Task.shutdown(task, :brutal_kill)
    assert :ok = ASM.stop_session(session)
  end

  test "driver crash emits an error event instead of timing out" do
    session_id = "stream-crash-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    events =
      ASM.stream(session, "hello", driver: CrashDriver, stream_timeout_ms: 100)
      |> Enum.to_list()

    assert Enum.any?(events, &(&1.kind == :error))

    error_event = Enum.find(events, &(&1.kind == :error))
    assert error_event.payload.kind == :runtime
    assert error_event.payload.message =~ "driver"

    assert :ok = ASM.stop_session(session)
  end

  test "execution_mode :remote_node requires remote driver configuration" do
    session_id = "stream-remote-config-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    assert {:error, error} = ASM.query(session, "hello", execution_mode: :remote_node)
    assert error.kind == :config_invalid
    assert error.message =~ "remote_node"

    assert :ok = ASM.stop_session(session)
  end

  test "explicit driver takes precedence over execution_mode" do
    session_id =
      "stream-driver-override-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    events =
      ASM.stream(session, "hello",
        execution_mode: :remote_node,
        driver: DelayedDriver,
        driver_opts: [text: "override-ok"]
      )
      |> Enum.to_list()

    assert Stream.final_result(events).text == "override-ok"
    assert :ok = ASM.stop_session(session)
  end

  test "invalid execution_mode fails with config error" do
    session_id = "stream-invalid-mode-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    assert {:error, error} = ASM.query(session, "hello", execution_mode: :invalid)
    assert error.kind == :config_invalid
    assert error.message =~ "execution_mode"

    assert :ok = ASM.stop_session(session)
  end

  test "text helpers expose deltas and composed content" do
    events = [
      %Event{
        id: Event.generate_id(),
        kind: :assistant_delta,
        run_id: "run-helpers",
        session_id: "session-helpers",
        payload: %Message.Partial{content_type: :text, delta: "a"},
        timestamp: DateTime.utc_now()
      },
      %Event{
        id: Event.generate_id(),
        kind: :assistant_message,
        run_id: "run-helpers",
        session_id: "session-helpers",
        payload: %Message.Assistant{content: [%Content.Text{text: "bc"}]},
        timestamp: DateTime.utc_now()
      },
      %Event{
        id: Event.generate_id(),
        kind: :assistant_delta,
        run_id: "run-helpers",
        session_id: "session-helpers",
        payload: %Message.Partial{content_type: :text, delta: "d"},
        timestamp: DateTime.utc_now()
      }
    ]

    assert Stream.text_deltas(events) |> Enum.to_list() == ["a", "d"]
    assert Stream.text_content(events) |> Enum.to_list() == ["a", "bc", "d"]
    assert Stream.final_text(events) == "abcd"
  end

  test "final_result/1 raises on empty event enumerable" do
    assert_raise ArgumentError, "stream produced no events", fn ->
      Stream.final_result([])
    end
  end
end
