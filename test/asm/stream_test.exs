defmodule ASM.StreamTest do
  use ASM.TestCase

  alias ASM.{Content, Event, Stream}
  alias ASM.TestSupport.FakeBackend
  alias CliSubprocessCore.Payload

  defmodule ContinuationRunProbe do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    @impl true
    def init(opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      run_id = Keyword.fetch!(opts, :run_id)
      session_id = Keyword.fetch!(opts, :session_id)
      subscriber = Keyword.fetch!(opts, :subscriber)

      send(test_pid, {:run_started, run_id, self()})
      send(test_pid, {:run_boot_opts, run_id, Keyword.take(opts, [:continuation])})

      send(
        subscriber,
        {:asm_run_event, run_id,
         Event.new(
           :run_started,
           Payload.RunStarted.new(command: "probe"),
           run_id: run_id,
           session_id: session_id,
           provider: :claude
         )}
      )

      {:ok, %{test_pid: test_pid, run_id: run_id}}
    end

    @impl true
    def handle_cast(:interrupt, state) do
      {:stop, :normal, state}
    end
  end

  test "create/3 emits backend-backed run events and final_result/1 projects text" do
    session_id = "stream-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    events =
      ASM.stream(session, "hello", backend_module: FakeBackend)
      |> Enum.to_list()

    assert Enum.any?(events, &(&1.kind == :run_started))
    assert Enum.any?(events, &(&1.kind == :assistant_delta))
    assert Enum.any?(events, &(&1.kind == :result))

    result = Stream.final_result(events)
    assert result.session_id == session_id
    assert result.text == "hello"

    assert :ok = ASM.stop_session(session)
  end

  test "invalid execution_mode fails with config error" do
    session_id = "stream-invalid-mode-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    assert {:error, error} = ASM.query(session, "hello", execution_mode: :invalid)
    assert error.kind == :config_invalid
    assert String.contains?(error.message, "execution_mode")

    assert :ok = ASM.stop_session(session)
  end

  test "execution_mode :remote_node is preserved at the public API boundary" do
    session_id = "stream-remote-mode-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    assert {:ok, result} =
             ASM.query(session, "hello",
               execution_mode: :remote_node,
               driver_opts: [remote_node: :asm@test],
               backend_module: FakeBackend
             )

    assert result.text == "hello"
    assert :ok = ASM.stop_session(session)
  end

  test "continuation is passed through ASM.stream/3 as a run option" do
    session_id = "stream-continuation-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    on_exit(fn -> :ok = ASM.stop_session(session) end)

    run_id = "stream-continuation-run"

    stream =
      ASM.stream(session, "continue",
        run_id: run_id,
        run_module: ContinuationRunProbe,
        run_module_opts: [test_pid: self()],
        continuation: %{strategy: :exact, provider_session_id: "claude-session-42"}
      )

    assert [%ASM.Event{kind: :run_started, run_id: ^run_id}] = Enum.take(stream, 1)
    assert_receive {:run_boot_opts, ^run_id, boot_opts}

    assert boot_opts[:continuation] == %{
             strategy: :exact,
             provider_session_id: "claude-session-42"
           }
  end

  test "text helpers expose deltas and composed content" do
    events = [
      Event.new(
        :assistant_delta,
        Payload.AssistantDelta.new(content: "a"),
        run_id: "run-helpers",
        session_id: "session-helpers"
      ),
      Event.new(
        :assistant_message,
        Payload.AssistantMessage.new(content: [%{"type" => "text", "text" => "bc"}]),
        run_id: "run-helpers",
        session_id: "session-helpers"
      ),
      Event.new(
        :assistant_delta,
        Payload.AssistantDelta.new(content: "d"),
        run_id: "run-helpers",
        session_id: "session-helpers"
      )
    ]

    assert Stream.text_deltas(events) |> Enum.to_list() == ["a", "d"]
    assert Stream.text_content(events) |> Enum.to_list() == ["a", "bc", "d"]
    assert Stream.final_text(events) == "abcd"

    legacy =
      %ASM.Message.Assistant{content: [%Content.Text{text: "legacy"}]}
      |> then(fn payload -> [payload] end)

    assert Stream.text_content(legacy) |> Enum.to_list() == ["legacy"]
  end

  test "final_result/1 raises on empty event enumerable" do
    assert_raise ArgumentError, "stream produced no events", fn ->
      Stream.final_result([])
    end
  end
end
