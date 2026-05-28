defmodule ASM.CursorLiveTest do
  use ASM.SerialTestCase

  @moduletag :live
  @moduletag :cursor

  test "live Cursor query and stream run through the core lane" do
    prompt = "Reply with exactly: CURSOR_OK and no extra text."

    assert {:ok, query_result} =
             ASM.query(:cursor, prompt,
               lane: :core,
               permission_mode: :bypass,
               transport_headless_timeout_ms: 120_000
             )

    assert String.contains?(query_result.text || "", "CURSOR_OK")

    session_id = "cursor-live-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, session} =
             ASM.start_session(
               session_id: session_id,
               provider: :cursor,
               lane: :core,
               permission_mode: :bypass,
               transport_headless_timeout_ms: 120_000
             )

    try do
      events = ASM.stream(session, prompt) |> Enum.to_list()
      result = ASM.Stream.final_result(events)

      assert Enum.any?(events, &(&1.kind == :assistant_delta or &1.kind == :assistant_message))
      assert String.contains?(result.text || "", "CURSOR_OK")
    after
      _ = ASM.stop_session(session)
    end
  end
end
