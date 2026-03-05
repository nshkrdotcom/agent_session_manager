defmodule ASM.Stream.SDKDriverTest do
  use ASM.TestCase

  alias ASM.{Event, Message, Stream}

  test "stream drivers expose explicit transport/sdk contract kind" do
    assert ASM.Stream.CLIDriver.kind() == :transport
    assert ASM.Stream.NodeDriver.kind() == :transport
    assert ASM.Stream.SDKDriver.kind() == :sdk
  end

  test "sdk driver streams normalized events without transport semantics" do
    session_id = "stream-sdk-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    events =
      ASM.stream(session, "hello",
        driver: ASM.Stream.SDKDriver,
        driver_opts: [
          stream_fun: fn _ctx ->
            [
              {:assistant_delta, %Message.Partial{content_type: :text, delta: "sdk "}},
              {:assistant_delta, %Message.Partial{content_type: :text, delta: "ok"}},
              {:result, %Message.Result{stop_reason: :end_turn}}
            ]
          end
        ]
      )
      |> Enum.to_list()

    assert Enum.any?(events, &(&1.kind == :run_started))
    refute Enum.any?(events, &(&1.kind == :error))
    assert Stream.final_result(events).text == "sdk ok"

    assert :ok = ASM.stop_session(session)
  end

  test "sdk driver emits terminal result when sdk stream ends without one" do
    session_id =
      "stream-sdk-default-result-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    events =
      ASM.stream(session, "hello",
        driver: ASM.Stream.SDKDriver,
        driver_opts: [
          stream_fun: fn _ctx ->
            [{:assistant_delta, %Message.Partial{content_type: :text, delta: "auto-result"}}]
          end
        ]
      )
      |> Enum.to_list()

    assert Stream.final_result(events).text == "auto-result"

    assert Enum.any?(events, fn
             %Event{kind: :result} -> true
             _ -> false
           end)

    assert :ok = ASM.stop_session(session)
  end

  test "sdk driver failures surface as runtime errors to stream consumers" do
    session_id = "stream-sdk-fail-" <> Integer.to_string(System.unique_integer([:positive]))
    assert {:ok, session} = ASM.start_session(session_id: session_id, provider: :claude)

    events =
      ASM.stream(session, "hello",
        driver: ASM.Stream.SDKDriver,
        stream_timeout_ms: 250,
        driver_opts: [
          stream_fun: fn _ctx ->
            raise "sdk exploded"
          end
        ]
      )
      |> Enum.to_list()

    error_event = Enum.find(events, &(&1.kind == :error))
    assert error_event.payload.kind == :runtime
    assert error_event.payload.message =~ "sdk"

    assert :ok = ASM.stop_session(session)
  end
end
