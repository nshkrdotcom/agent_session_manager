defmodule ASM.StreamTest do
  use ExUnit.Case, async: true

  alias ASM.Stream

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

  test "final_result/1 raises on empty event enumerable" do
    assert_raise ArgumentError, "stream produced no events", fn ->
      Stream.final_result([])
    end
  end
end
