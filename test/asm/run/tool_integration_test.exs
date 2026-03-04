defmodule ASM.Run.ToolIntegrationTest do
  use ASM.TestCase

  alias ASM.{Event, Message, Run}

  test "tool_use event triggers tool execution and emits tool_result" do
    tools = %{"echo" => fn input, _ctx -> {:ok, input["text"]} end}

    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-tool-int",
               session_id: "session-tool-int",
               provider: :claude,
               subscriber: self(),
               tools: tools
             )

    assert_receive {:asm_run_event, "run-tool-int", %Event{kind: :run_started}}

    tool_use_event =
      %Event{
        id: Event.generate_id(),
        kind: :tool_use,
        run_id: "run-tool-int",
        session_id: "session-tool-int",
        payload: %Message.ToolUse{
          tool_name: "echo",
          tool_id: "tool-int-1",
          input: %{"text" => "tool-ok"}
        },
        timestamp: DateTime.utc_now()
      }

    assert :ok = Run.Server.ingest_event(run_pid, tool_use_event)

    assert_receive {:asm_run_event, "run-tool-int", %Event{kind: :tool_use}}

    assert_receive {:asm_run_event, "run-tool-int",
                    %Event{
                      kind: :tool_result,
                      payload: %Message.ToolResult{
                        tool_id: "tool-int-1",
                        content: "tool-ok",
                        is_error: false
                      }
                    }}
  end

  test "tool_use with missing tool emits error tool_result" do
    assert {:ok, run_pid} =
             Run.Server.start_link(
               run_id: "run-tool-int-missing",
               session_id: "session-tool-int-missing",
               provider: :claude,
               subscriber: self(),
               tools: %{}
             )

    assert_receive {:asm_run_event, "run-tool-int-missing", %Event{kind: :run_started}}

    tool_use_event =
      %Event{
        id: Event.generate_id(),
        kind: :tool_use,
        run_id: "run-tool-int-missing",
        session_id: "session-tool-int-missing",
        payload: %Message.ToolUse{
          tool_name: "not_found",
          tool_id: "tool-int-2",
          input: %{}
        },
        timestamp: DateTime.utc_now()
      }

    assert :ok = Run.Server.ingest_event(run_pid, tool_use_event)

    assert_receive {:asm_run_event, "run-tool-int-missing",
                    %Event{
                      kind: :tool_result,
                      payload: %Message.ToolResult{
                        tool_id: "tool-int-2",
                        is_error: true
                      }
                    }}
  end
end
